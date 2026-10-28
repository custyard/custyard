defmodule Custyard.Email.ImapPoll do
  @moduledoc """
  One IMAP session for one channel (spec-inbound-channels, D8).

  The folder is opened read-only. The channel remembers how far it has read
  as `imap_uid_validity` plus `imap_last_uid`; nothing in the mailbox is
  marked, moved or deleted, so the staff's own mail client sees the
  mailbox exactly as before.

    * `establish/2` checks the credentials and, for a mailbox without a
      position, records the starting one: the highest UID already in the
      folder, so connecting a mailbox never imports its history. A channel
      that already has a position on the same folder keeps it.
    * `poll/2` imports messages above the position, at most
      50 per session, in UID order. The position advances past every
      message that was handled, including ones logged to the rejection log
      (over the size cap, unreadable) and ones the pipeline refused, so one
      bad message never blocks the folder. It stops without advancing when
      the connection or the database fails, and the next poll retries.
      A message whose attachments could not be stored stops the session
      the same way, for up to 5 sessions; after that it is passed over,
      stored with its attachments marked failed. Every message
      carries a delivery id made of the channel, UIDVALIDITY and UID, so a
      retried message is never stored twice.
    * A changed UIDVALIDITY means the server renumbered the folder: the
      position is reset to the current highest UID and a warning logged.

  Every session runs in a task with a 120-second deadline: Plover's TLS
  connect has no timeout of its own. Results land on the channel
  (`imap_last_polled_at`, `imap_last_error`, `imap_consecutive_failures`).
  Three rejected logins without a successful session in between set
  `imap_auth_failed_at`, which stops polling until the credentials are
  changed: providers lock accounts that keep failing to log in. Other
  failures neither count towards that nor reset it. Errors are recorded
  as short codes and never carry server responses.
  """

  require Logger

  import Ecto.Query

  alias Custyard.{Credentials, InboundChannel, InboundChannels, InboundRoute, Repo, Tenant}
  alias Custyard.Email.{ImapClient, ImapHost, Parser}
  alias Custyard.Webhooks.Adapters.Email, as: EmailAdapter
  alias Custyard.Webhooks.Dispatcher

  @max_messages_per_poll 50
  @max_message_bytes 25 * 1024 * 1024
  @session_timeout_ms 120_000
  @cleanup_timeout_ms 1_000
  @auth_failures_before_suspend 3
  @max_message_attempts 5
  @retryable_dispatch_errors [:attachment_fetch_failed, :attachment_processing_failed]

  @error_codes %{
    auth_failed: "auth_failed",
    folder_unavailable: "folder_unavailable",
    no_uid_validity: "folder_unavailable",
    disallowed_host: "disallowed_host",
    unresolvable: "unresolvable",
    credentials_unreadable: "credentials_unreadable",
    timeout: "timeout",
    session_crashed: "session_crashed",
    database_unavailable: "database_unavailable",
    attachments_failed: "attachments_failed",
    channel_deleted: "channel_deleted",
    tenant_suspended: "tenant_suspended"
  }

  def max_messages_per_poll, do: @max_messages_per_poll
  def max_message_bytes, do: @max_message_bytes

  @doc """
  Log in, open the folder and, unless the channel already has a position
  under the folder's current UIDVALIDITY, record the starting position.
  Clears any earlier error and a login lockout. `{:ok, channel}` or `{:error, code}` (see `error_code/1`),
  with the error also recorded on the channel.
  """
  def establish(%InboundChannel{ingress_kind: :imap} = channel, opts \\ []) do
    with {:ok, current} <- current_channel(channel) do
      establish_current(current, opts)
    end
  end

  defp establish_current(channel, opts) do
    result =
      run(channel, opts, fn client, conn, mailbox ->
        position(client, conn, channel, mailbox)
      end)

    persist = Keyword.get(opts, :persist, fn fun -> fun.() end)

    persist.(fn ->
      case result do
        {:ok, position} ->
          record(
            channel,
            Map.merge(position, %{
              imap_last_polled_at: now(),
              imap_last_error: nil,
              imap_consecutive_failures: 0,
              imap_auth_failures: 0,
              imap_auth_failed_at: nil
            })
          )

        {:error, reason} ->
          record_failure(channel, reason)
          {:error, error_code(reason)}
      end
    end)
  end

  @doc """
  Import new mail. `{:ok, %{imported: n, ignored: n, skipped: n, failed: n}}`
  (`rebased: true` when UIDVALIDITY changed) or `{:error, code}`. A channel
  without a starting position is established first.
  """
  def poll(channel, opts \\ [])

  def poll(%InboundChannel{ingress_kind: :imap} = channel, opts) do
    with {:ok, current} <- current_channel(channel) do
      poll_current(current, opts)
    end
  end

  defp poll_current(%InboundChannel{imap_uid_validity: nil} = channel, opts) do
    with {:ok, _channel} <- establish(channel, opts) do
      {:ok, %{imported: 0, ignored: 0, skipped: 0, failed: 0, rebased: true}}
    end
  end

  defp poll_current(channel, opts) do
    route = Repo.get!(InboundRoute, channel.inbound_route_id)

    result =
      run(channel, opts, fn client, conn, mailbox ->
        if mailbox.uid_validity == channel.imap_uid_validity do
          import_new(client, conn, channel, route)
        else
          rebase(client, conn, channel, mailbox)
        end
      end)

    case result do
      {:ok, counts} ->
        record(channel, %{
          imap_last_polled_at: now(),
          imap_last_error: nil,
          imap_consecutive_failures: 0,
          imap_auth_failures: 0,
          imap_message_attempts: 0
        })

        {:ok, counts}

      {:error, reason} ->
        record_failure(channel, reason)
        {:error, error_code(reason)}
    end
  end

  # --- Session ---

  # Connect, log in, examine, run `fun`, log out; all inside a task with a
  # deadline. The task's callers chain lets it use the caller's database
  # connection in tests.
  defp run(channel, opts, fun) do
    client = Keyword.get_lazy(opts, :client, &ImapClient.client/0)
    timeout = Keyword.get(opts, :timeout, @session_timeout_ms)

    owner = self()

    task =
      Task.Supervisor.async_nolink(Custyard.TaskSupervisor, fn ->
        worker = self()
        guard = spawn(fn -> guard_session(owner, worker, client, nil) end)

        try do
          session(client, channel, opts, fun, guard)
        after
          send(guard, :done)
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, _reason} -> {:error, :session_crashed}
      nil -> {:error, :timeout}
    end
  end

  # A supervised, unlinked session must still belong to its polling caller.
  # The guard also closes an acquired connection if cancellation skips `after`.
  defp guard_session(owner, worker, client, conn) do
    owner_ref = Process.monitor(owner)
    worker_ref = Process.monitor(worker)
    guard_session_loop(owner_ref, worker_ref, worker, client, conn)
  end

  defp guard_session_loop(owner_ref, worker_ref, worker, client, conn) do
    receive do
      {:connection, connection} ->
        guard_session_loop(owner_ref, worker_ref, worker, client, connection)

      {:DOWN, ^owner_ref, :process, _owner, _reason} ->
        Process.exit(worker, :kill)
        close_cancelled_session(client, conn)

      {:DOWN, ^worker_ref, :process, ^worker, _reason} ->
        close_cancelled_session(client, conn)

      :done ->
        :ok
    end
  end

  defp close_cancelled_session(_client, nil), do: :ok

  defp close_cancelled_session(client, conn) do
    {cleanup, ref} = spawn_monitor(fn -> safe_logout(client, conn) end)

    receive do
      {:DOWN, ^ref, :process, ^cleanup, _reason} -> :ok
    after
      @cleanup_timeout_ms ->
        Process.exit(cleanup, :kill)
        Process.demonitor(ref, [:flush])
    end

    # Plover transfers SSL ownership to a connection linked to the session.
    # Killing the session already closes that connection, including the gap
    # between connect returning and the guard receiving its handle.
    if is_pid(conn), do: Process.exit(conn, :kill)
    :ok
  end

  defp safe_logout(client, conn) do
    client.logout(conn)
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp session(client, channel, opts, fun, guard) do
    with {:ok, channel} <- current_channel(channel),
         {:ok, password} <- password(channel),
         {:ok, address, server_name} <- ImapHost.resolve(channel.imap_host),
         {:ok, conn} <-
           client.connect(
             address,
             channel.imap_port,
             [server_name: server_name] ++ Keyword.get(opts, :connect, [])
           ) do
      send(guard, {:connection, conn})

      try do
        with :ok <- client.login(conn, channel.imap_username, password),
             {:ok, mailbox} <- client.examine(conn, channel.imap_folder),
             {:ok, _current} <- current_channel(channel) do
          maybe_reencrypt(channel, password)
          fun.(client, conn, mailbox)
        end
      after
        client.logout(conn)
      end
    else
      {:error, :invalid} -> {:error, :credentials_unreadable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp password(channel) do
    case InboundChannel.imap_password(channel) do
      {:ok, password} -> {:ok, password}
      {:error, :invalid} -> {:error, :credentials_unreadable}
    end
  end

  # A password sealed with a previous key is moved to the current one once
  # it has been used successfully, unless the staff saved a new password
  # while this session was logging in.
  defp maybe_reencrypt(%InboundChannel{imap_password_ciphertext: read} = channel, password) do
    if Credentials.stale?(read) do
      with {:ok, ciphertext} <-
             Credentials.encrypt(password, InboundChannel.imap_password_context()) do
        from(c in InboundChannel,
          where: c.id == ^channel.id and c.imap_password_ciphertext == ^read
        )
        |> Repo.update_all(set: [imap_password_ciphertext: ciphertext, updated_at: now()])
      end
    end
  end

  # A channel that already has a position on this folder keeps it: a
  # reconnect after a login lockout, or a connection test, must still import
  # what arrived in the meantime. Only a new mailbox or a renumbered folder
  # starts from the newest message. Changing host, username or folder clears
  # the position first (InboundChannel.changeset/2).
  defp position(_client, _conn, %InboundChannel{imap_uid_validity: validity}, %{
         uid_validity: validity
       })
       when is_integer(validity),
       do: {:ok, %{}}

  defp position(client, conn, _channel, mailbox) do
    with {:ok, uid} <- starting_uid(client, conn, mailbox) do
      {:ok,
       %{imap_uid_validity: mailbox.uid_validity, imap_last_uid: uid, imap_message_attempts: 0}}
    end
  end

  defp starting_uid(_client, _conn, %{uid_next: next}) when is_integer(next) and next > 0,
    do: {:ok, next - 1}

  defp starting_uid(client, conn, _mailbox) do
    case client.highest_uid(conn) do
      {:ok, nil} -> {:ok, 0}
      {:ok, uid} -> {:ok, uid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp rebase(client, conn, channel, mailbox) do
    with {:ok, uid} <- starting_uid(client, conn, mailbox),
         {:ok, _} <- save_baseline(channel, mailbox.uid_validity, uid) do
      Logger.warning(
        "IMAP channel #{channel.id}: UIDVALIDITY changed, position reset to UID #{uid}"
      )

      {:ok, %{imported: 0, ignored: 0, skipped: 0, failed: 0, rebased: true}}
    end
  end

  # --- Import ---

  # `attempts` counts the sessions that already stopped on the message at
  # the current position; once one message advances, the next starts at 0.
  defp import_new(client, conn, channel, route) do
    with {:ok, listed} <- client.list_after(conn, channel.imap_last_uid || 0) do
      listed
      |> Enum.take(@max_messages_per_poll)
      |> Enum.reduce_while(
        {:ok, %{imported: 0, ignored: 0, skipped: 0, failed: 0}, channel.imap_message_attempts},
        fn item, {:ok, counts, attempts} ->
          result =
            case current_channel(channel) do
              {:ok, current} -> import_one(client, conn, current, route, item)
              {:error, reason} -> {:stop, reason}
            end

          case settle(result, channel, item, attempts) do
            {:advance, outcome} ->
              advance(channel, item.uid)
              {:cont, {:ok, Map.update!(counts, outcome, &(&1 + 1)), 0}}

            {:stop, reason} ->
              {:halt, {:error, reason}}
          end
        end
      )
      |> case do
        {:ok, counts, _attempts} -> {:ok, counts}
        error -> error
      end
    end
  end

  # A retry stops the session until the message has had its attempts; then
  # it is passed over like a message the pipeline refused.
  defp settle({:retry, reason}, channel, item, attempts) do
    if attempts + 1 >= @max_message_attempts do
      Logger.warning(
        "IMAP channel #{channel.id}: UID #{item.uid} passed over after #{@max_message_attempts} attempts: #{inspect(reason)}"
      )

      {:advance, :failed}
    else
      {:stop, :attachments_failed}
    end
  end

  defp settle(result, _channel, _item, _attempts), do: result

  defp import_one(_client, _conn, channel, route, %{size: size})
       when is_integer(size) and size > @max_message_bytes do
    InboundChannels.log_rejection(route, :too_large, %{
      recipient: channel.public_address,
      inbound_channel_id: channel.id
    })

    {:advance, :skipped}
  end

  defp import_one(client, conn, channel, route, %{uid: uid}) do
    case client.fetch_message(conn, uid) do
      {:ok, raw} ->
        case current_channel(channel) do
          {:ok, current} -> dispatch(raw, current, route, uid)
          {:error, reason} -> {:stop, reason}
        end

      {:error, reason} ->
        {:stop, {:fetch_failed, reason}}
    end
  end

  defp dispatch(raw, channel, route, uid) do
    with {:ok, parsed} <- Parser.parse(raw),
         {:ok, normalized} <- EmailAdapter.normalize(parsed) do
      normalized = put_delivery_id(normalized, channel, uid)

      case Dispatcher.dispatch(route, normalized, channel: channel) do
        {:ok, _thread} ->
          {:advance, :imported}

        {:ignored, _reason} ->
          {:advance, :ignored}

        # The message is stored; its attachments are not yet. Retrying
        # resumes them (Purposes.Attachments) without a second copy.
        {:error, reason} when reason in @retryable_dispatch_errors ->
          {:retry, reason}

        {:error, reason} ->
          Logger.warning(
            "IMAP channel #{channel.id}: UID #{uid} not imported: #{inspect(error_class(reason))}"
          )

          {:advance, :failed}
      end
    else
      _unparseable ->
        InboundChannels.log_rejection(route, :unreadable, %{
          recipient: channel.public_address,
          inbound_channel_id: channel.id
        })

        {:advance, :skipped}
    end
  rescue
    # The database being busy says nothing about the message: stop here and
    # retry it on the next poll.
    _error in [DBConnection.ConnectionError, Exqlite.Error] ->
      Logger.warning("IMAP channel #{channel.id}: database unavailable at UID #{uid}")
      {:stop, :database_unavailable}

    # A message that crashes the pipeline must not block the folder.
    error ->
      Logger.error("IMAP channel #{channel.id}: UID #{uid} raised #{inspect(error.__struct__)}")

      {:advance, :failed}
  end

  # Identifies the message across retries, with or without a Message-ID.
  defp put_delivery_id(normalized, channel, uid) do
    id = "imap:#{channel.id}:#{channel.imap_uid_validity}:#{uid}"

    Map.update(
      normalized,
      :metadata,
      %{provider_delivery_id: id},
      &Map.put(&1, :provider_delivery_id, id)
    )
  end

  defp error_class(%Ecto.Changeset{errors: errors}), do: {:invalid, Keyword.keys(errors)}
  defp error_class(reason) when is_atom(reason), do: reason
  defp error_class({reason, _detail}) when is_atom(reason), do: reason
  defp error_class(_reason), do: :error

  # --- Persistence ---

  # Forward-only: a concurrent poll (two nodes) can never move it back.
  defp advance(channel, uid) do
    active_tenants = from(t in Tenant, where: t.status == "active", select: t.id)

    from(c in InboundChannel,
      where:
        c.id == ^channel.id and c.tenant_id in subquery(active_tenants) and
          (is_nil(c.imap_last_uid) or c.imap_last_uid < ^uid)
    )
    |> Repo.update_all(set: [imap_last_uid: uid, imap_message_attempts: 0, updated_at: now()])
  end

  defp save_baseline(channel, validity, uid) do
    record(channel, %{imap_uid_validity: validity, imap_last_uid: uid, imap_message_attempts: 0})
  end

  defp record(channel, attrs) do
    Repo.transaction(fn ->
      with {:ok, current} <- current_channel(channel),
           {:ok, updated} <-
             current |> InboundChannel.imap_state_changeset(attrs) |> Repo.update() do
        InboundChannels.broadcast(updated)
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp record_failure(channel, reason) do
    with {:ok, current} <- current_channel(channel) do
      record(current, failure_attrs(current, error_code(reason)))
    end

    :ok
  end

  # Resolve ownership from the stored channel, never from a stale caller snapshot.
  defp current_channel(%InboundChannel{id: id}) do
    case Repo.get(InboundChannel, id) do
      nil ->
        {:error, :channel_deleted}

      channel ->
        case Repo.get(Tenant, channel.tenant_id) do
          %Tenant{status: "active"} -> {:ok, channel}
          _ -> {:error, :tenant_suspended}
        end
    end
  end

  # Every failure counts towards backoff. Only a rejected login counts
  # towards suspension, and only an attachment failure towards passing the
  # message over.
  defp failure_attrs(current, code) do
    auth_failures = count_if(current.imap_auth_failures, code == "auth_failed")

    %{
      imap_last_error: code,
      imap_consecutive_failures: current.imap_consecutive_failures + 1,
      imap_auth_failures: auth_failures,
      imap_message_attempts:
        count_if(current.imap_message_attempts, code == "attachments_failed"),
      imap_auth_failed_at:
        if(auth_failures >= @auth_failures_before_suspend,
          do: current.imap_auth_failed_at || now(),
          else: current.imap_auth_failed_at
        )
    }
  end

  defp count_if(count, true), do: count + 1
  defp count_if(count, false), do: count

  @doc """
  Short code for a session failure, stored as `imap_last_error` and shown
  to the staff. Never the server's own text.
  """
  def error_code(reason) when is_atom(reason), do: Map.get(@error_codes, reason, "connect_failed")
  def error_code({tag, _detail}) when tag in [:fetch_failed, :list_failed], do: "fetch_failed"
  def error_code({tag, _detail}) when tag in [:tls_alert, :options], do: "tls_failed"
  def error_code(code) when is_binary(code), do: code
  def error_code(_reason), do: "connect_failed"

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
