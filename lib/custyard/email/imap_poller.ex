defmodule Custyard.Email.ImapPoller do
  @moduledoc """
  GenServer that polls an IMAP mailbox for new emails.

  Periodically connects to the configured IMAP server, fetches UNSEEN messages,
  processes them through the existing email pipeline (Parser -> Processor),
  and marks them as SEEN.

  Configuration (in config/runtime.exs):

      config :custyard, :imap,
        enabled: true,
        host: "imap.example.com",
        port: 993,
        username: "user@example.com",
        password: "secret",
        folder: "INBOX",
        poll_interval: 60_000,
        ssl: true
  """

  use GenServer

  require Logger

  alias Custyard.Email.{Parser, Processor}

  @default_poll_interval 60_000
  @default_folder "INBOX"
  @default_port 993

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc """
  Manually trigger a poll. Useful for testing.
  """
  def poll_now do
    GenServer.cast(__MODULE__, :poll)
  end

  @doc """
  Get the current state (for debugging/monitoring).
  """
  def get_state do
    GenServer.call(__MODULE__, :get_state)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    state = %{
      host: Keyword.fetch!(opts, :host),
      port: Keyword.get(opts, :port, @default_port),
      username: Keyword.fetch!(opts, :username),
      password: Keyword.fetch!(opts, :password),
      folder: Keyword.get(opts, :folder, @default_folder),
      poll_interval: Keyword.get(opts, :poll_interval, @default_poll_interval),
      ssl: Keyword.get(opts, :ssl, true),
      last_poll: nil,
      messages_processed: 0,
      errors: 0
    }

    Logger.info("IMAP poller starting for #{state.username}@#{state.host}:#{state.port}")

    # Schedule first poll
    schedule_poll(state.poll_interval)

    {:ok, state}
  end

  @impl true
  def handle_cast(:poll, state) do
    new_state = do_poll(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get_state, _from, state) do
    # Return state without sensitive data
    safe_state = Map.drop(state, [:password])
    {:reply, safe_state, state}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state = do_poll(state)
    schedule_poll(state.poll_interval)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.debug("IMAP poller received unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  # Private Functions

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
  end

  defp do_poll(state) do
    Logger.debug("IMAP polling #{state.folder} on #{state.host}")

    case poll_mailbox(state) do
      {:ok, processed_count} ->
        Logger.info("IMAP poll complete: #{processed_count} messages processed")

        %{
          state
          | last_poll: DateTime.utc_now(),
            messages_processed: state.messages_processed + processed_count
        }

      {:error, reason} ->
        Logger.warning("IMAP poll failed: #{inspect(reason)}")
        %{state | errors: state.errors + 1}
    end
  end

  defp poll_mailbox(state) do
    with {:ok, conn} <- connect(state),
         {:ok, _} <- Plover.login(conn, state.username, state.password),
         {:ok, _} <- Plover.select(conn, state.folder),
         {:ok, messages} <- fetch_unseen(conn),
         processed <- process_messages(conn, messages) do
      # Always try to logout, ignore errors
      Plover.logout(conn)
      {:ok, processed}
    else
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp connect(state) do
    opts = [
      port: state.port,
      ssl: state.ssl
    ]

    Plover.connect(state.host, opts)
  end

  defp fetch_unseen(conn) do
    # Search for unseen messages
    # Note: Plover's ESearch.all is a string (e.g., "1,3,5" or "1:10"), not a list
    case Plover.search(conn, "UNSEEN") do
      {:ok, %{all: nil}} ->
        {:ok, []}

      {:ok, %{all: ""}} ->
        {:ok, []}

      {:ok, %{all: sequence_set}} when is_binary(sequence_set) ->
        # Fetch envelope and UID for unseen messages
        Plover.fetch(conn, sequence_set, [:uid, :envelope, :flags])

      {:error, reason} ->
        {:error, {:search_failed, reason}}
    end
  end

  defp process_messages(_conn, []), do: 0

  defp process_messages(conn, messages) do
    messages
    |> Enum.map(fn msg -> process_single_message(conn, msg) end)
    |> Enum.count(&(&1 == :ok))
  end

  defp process_single_message(conn, msg) do
    uid = msg.attrs[:uid]

    Logger.debug("Processing IMAP message UID: #{uid}")

    with {:ok, raw_email} <- fetch_raw_email(conn, uid),
         {:ok, parsed} <- Parser.parse(raw_email),
         {:ok, _conversation} <- Processor.process(parsed) do
      # Mark as seen after successful processing
      mark_as_seen(conn, uid)
      Logger.debug("Successfully processed IMAP message UID: #{uid}")
      :ok
    else
      {:error, reason} ->
        Logger.warning("Failed to process IMAP message UID #{uid}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp fetch_raw_email(conn, uid) do
    # Fetch full RFC 5322 message body without marking as seen
    # Empty string section means entire message
    case Plover.uid_fetch(conn, "#{uid}", [{:body_peek, ""}]) do
      {:ok, [msg]} ->
        body = get_in(msg.attrs, [:body, ""]) || get_in(msg.attrs, ["BODY[]"])

        if body do
          {:ok, body}
        else
          {:error, :no_body}
        end

      {:ok, []} ->
        {:error, :message_not_found}

      {:error, reason} ->
        {:error, {:fetch_failed, reason}}
    end
  end

  defp mark_as_seen(conn, uid) do
    case Plover.uid_store(conn, "#{uid}", :add, [:seen]) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to mark message #{uid} as seen: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
