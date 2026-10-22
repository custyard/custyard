defmodule Custyard.Email.ImapPoll do
  @moduledoc """
  One IMAP session for one channel (spec-inbound-channels, D8).

  The folder is opened read-only. The channel remembers how far it has read
  as `imap_uid_validity` plus `imap_last_uid`; nothing in the mailbox is
  marked, moved or deleted, so the operator's own mail client sees the
  mailbox exactly as before.

    * `establish/2` checks the credentials and records the starting
      position: the highest UID already in the folder, so connecting a
      mailbox never imports its history.
    * `poll/2` imports messages above the position, at most
      50 per session, in UID order. The position advances past every
      message that was handled, including ones logged to the rejection log
      (over the size cap, unreadable) and ones the pipeline refused, so one
      bad message never blocks the folder. It stops without advancing when
      the connection or the database fails, and the next poll retries.
      Message-ID deduplication makes a retried message harmless.
    * A changed UIDVALIDITY means the server renumbered the folder: the
      position is reset to the current highest UID and a warning logged.

  Every session runs in a task with a 120-second deadline: Plover's TLS
  connect has no timeout of its own. Results land on the channel
  (`imap_last_polled_at`, `imap_last_error`, `imap_consecutive_failures`).
  Three login failures in a row set `imap_auth_failed_at`, which stops
  polling until the credentials are changed: providers lock accounts that
  keep failing to log in. Errors are recorded as short codes and never
  carry server responses.
  """

  require Logger

  import Ecto.Query

  alias Custyard.{Credentials, InboundChannel, InboundChannels, InboundRoute, Repo}
  alias Custyard.Email.{ImapClient, ImapHost, Parser}
  alias Custyard.Webhooks.Adapters.Email, as: EmailAdapter
  alias Custyard.Webhooks.Dispatcher

  @max_messages_per_poll 50
  @max_message_bytes 25 * 1024 * 1024
  @session_timeout_ms 120_000
  @auth_failures_before_suspend 3

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
    channel_deleted: "channel_deleted"
  }

  def max_messages_per_poll, do: @max_messages_per_poll
  def max_message_bytes, do: @max_message_bytes

  @doc """
  Log in, open the folder and record the starting position. Clears any
  earlier error. `{:ok, channel}` or `{:error, code}` (see `error_code/1`),
  with the error also recorded on the channel.
  """
  def establish(%InboundChannel{ingress_kind: :imap} = channel, opts \\ []) do
    result =
      run(channel, opts, fn client, conn, mailbox ->
        with {:ok, uid} <- starting_uid(client, conn, mailbox) do
          {:ok, %{uid_validity: mailbox.uid_validity, last_uid: uid}}
        end
      end)

    case result do
      {:ok, %{uid_validity: validity, last_uid: uid}} ->
        record(channel, %{
          imap_uid_validity: validity,
          imap_last_uid: uid,
          imap_last_polled_at: now(),
          imap_last_error: nil,
          imap_consecutive_failures: 0,
          imap_auth_failed_at: nil
        })

      {:error, reason} ->
        record_failure(channel, reason)
        {:error, error_code(reason)}
    end
  end

  @doc """
  Import new mail. `{:ok, %{imported: n, ignored: n, skipped: n, failed: n}}`
  (`rebased: true` when UIDVALIDITY changed) or `{:error, code}`. A channel
  without a starting position is established first.
  """
  def poll(channel, opts \\ [])

  def poll(%InboundChannel{ingress_kind: :imap, imap_uid_validity: nil} = channel, opts) do
    with {:ok, _channel} <- establish(channel, opts) do
      {:ok, %{imported: 0, ignored: 0, skipped: 0, failed: 0, rebased: true}}
    end
  end

  def poll(%InboundChannel{ingress_kind: :imap} = channel, opts) do
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
          imap_consecutive_failures: 0
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

    task =
      Task.Supervisor.async_nolink(Custyard.TaskSupervisor, fn ->
        session(client, channel, opts, fun)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, _reason} -> {:error, :session_crashed}
      nil -> {:error, :timeout}
    end
  end

  defp session(client, channel, opts, fun) do
    with {:ok, password} <- password(channel),
         {:ok, address, server_name} <- ImapHost.resolve(channel.imap_host),
         {:ok, conn} <-
           client.connect(
             address,
             channel.imap_port,
             [server_name: server_name] ++ Keyword.get(opts, :connect, [])
           ) do
      try do
        with :ok <- client.login(conn, channel.imap_username, password),
             {:ok, mailbox} <- client.examine(conn, channel.imap_folder) do
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
  # it has been used successfully.
  defp maybe_reencrypt(channel, password) do
    if Credentials.stale?(channel.imap_password_ciphertext) do
      with {:ok, ciphertext} <-
             Credentials.encrypt(password, InboundChannel.imap_password_context()) do
        record(channel, %{imap_password_ciphertext: ciphertext})
      end
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

  defp import_new(client, conn, channel, route) do
    with {:ok, listed} <- client.list_after(conn, channel.imap_last_uid || 0) do
      listed
      |> Enum.take(@max_messages_per_poll)
      |> Enum.reduce_while(
        {:ok, %{imported: 0, ignored: 0, skipped: 0, failed: 0}},
        fn item, {:ok, counts} ->
          case import_one(client, conn, channel, route, item) do
            {:advance, outcome} ->
              advance(channel, item.uid)
              {:cont, {:ok, Map.update!(counts, outcome, &(&1 + 1))}}

            {:stop, reason} ->
              {:halt, {:error, reason}}
          end
        end
      )
    end
  end

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
      {:ok, raw} -> dispatch(raw, channel, route, uid)
      {:error, reason} -> {:stop, {:fetch_failed, reason}}
    end
  end

  defp dispatch(raw, channel, route, uid) do
    with {:ok, parsed} <- Parser.parse(raw),
         {:ok, normalized} <- EmailAdapter.normalize(parsed) do
      case Dispatcher.dispatch(route, normalized, channel: channel) do
        {:ok, _conversation} ->
          {:advance, :imported}

        {:ignored, _reason} ->
          {:advance, :ignored}

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

  defp error_class(%Ecto.Changeset{errors: errors}), do: {:invalid, Keyword.keys(errors)}
  defp error_class(reason) when is_atom(reason), do: reason
  defp error_class({reason, _detail}) when is_atom(reason), do: reason
  defp error_class(_reason), do: :error

  # --- Persistence ---

  # Forward-only: a concurrent poll (two nodes) can never move it back.
  defp advance(channel, uid) do
    from(c in InboundChannel,
      where: c.id == ^channel.id and (is_nil(c.imap_last_uid) or c.imap_last_uid < ^uid)
    )
    |> Repo.update_all(set: [imap_last_uid: uid, updated_at: now()])
  end

  defp save_baseline(channel, validity, uid) do
    record(channel, %{imap_uid_validity: validity, imap_last_uid: uid})
  end

  defp record(channel, attrs) do
    case Repo.get(InboundChannel, channel.id) do
      nil ->
        {:error, :channel_deleted}

      current ->
        with {:ok, updated} <-
               current |> InboundChannel.imap_state_changeset(attrs) |> Repo.update() do
          InboundChannels.broadcast(updated)
          {:ok, updated}
        end
    end
  end

  defp record_failure(channel, reason) do
    case Repo.get(InboundChannel, channel.id) do
      nil ->
        :ok

      current ->
        code = error_code(reason)
        failures = current.imap_consecutive_failures + 1

        suspend? =
          code == "auth_failed" and current.imap_last_error == "auth_failed" and
            failures >= @auth_failures_before_suspend

        record(current, %{
          imap_last_error: code,
          imap_consecutive_failures: failures,
          imap_auth_failed_at: if(suspend?, do: now(), else: current.imap_auth_failed_at)
        })

        :ok
    end
  end

  @doc """
  Short code for a session failure, stored as `imap_last_error` and shown
  to the operator. Never the server's own text.
  """
  def error_code(reason) when is_atom(reason), do: Map.get(@error_codes, reason, "connect_failed")
  def error_code({tag, _detail}) when tag in [:fetch_failed, :list_failed], do: "fetch_failed"
  def error_code({tag, _detail}) when tag in [:tls_alert, :options], do: "tls_failed"
  def error_code(code) when is_binary(code), do: code
  def error_code(_reason), do: "connect_failed"

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
