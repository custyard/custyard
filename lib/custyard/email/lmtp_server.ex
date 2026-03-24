# credo:disable-for-this-file Credo.Check.Readability.FunctionNames
defmodule Custyard.Email.LMTPServer do
  @moduledoc """
  LMTP server for receiving emails from MTAs.

  Uses gen_smtp's server callback behavior to accept incoming mail.
  Parses raw RFC 5322 email and forwards to Processor for handling.

  Note: This module implements the :gen_smtp_server_session behaviour which
  requires callback names like handle_HELO, handle_DATA, etc. These names
  are dictated by the Erlang library and cannot be changed.

  Configuration (in config/runtime.exs):

      config :custyard, :lmtp,
        enabled: true,
        port: 2024,
        hostname: "localhost"
  """

  require Logger

  @behaviour :gen_smtp_server_session

  alias Custyard.Email.{Parser, Processor}

  # Client API

  @doc """
  Start the LMTP server under the supervision tree.
  Returns a child specification.
  """
  def child_spec(opts) do
    port = Keyword.get(opts, :port, 2024)
    hostname = Keyword.get(opts, :hostname, "localhost")

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[port: port, hostname: hostname]]},
      type: :worker,
      restart: :permanent
    }
  end

  @doc """
  Start the LMTP server.

  Returns `{:ok, pid}` where pid is the ranch listener pid.
  The server is registered under a name based on the port (e.g., `:lmtp_server_2024`).
  """
  def start_link(opts) do
    port = Keyword.get(opts, :port, 2024)
    hostname = Keyword.get(opts, :hostname, "localhost") |> to_charlist()

    # Use a unique server name based on port to allow multiple instances (for testing)
    server_name = Keyword.get(opts, :name, server_name_for_port(port))

    # LMTP protocol option goes inside sessionoptions, not at the top level
    # The top-level protocol option is for transport (tcp/ssl)
    server_opts = [
      port: port,
      domain: hostname,
      sessionoptions: [
        protocol: :lmtp,
        callbackoptions: []
      ]
    ]

    Logger.info("Starting LMTP server on port #{port}")
    :gen_smtp_server.start(server_name, __MODULE__, server_opts)
  end

  @doc """
  Stop the LMTP server.

  Accepts either a pid (which will be looked up to find the server name)
  or an atom server name directly.
  """
  def stop(pid_or_name) when is_pid(pid_or_name) do
    # Find the listener name from the pid by checking all running ranch listeners
    name = find_listener_name_for_pid(pid_or_name)
    :gen_smtp_server.stop(name || pid_or_name)
  end

  def stop(name) when is_atom(name) do
    :gen_smtp_server.stop(name)
  end

  defp find_listener_name_for_pid(pid) do
    listeners = :ranch.info()
    find_name_in_listeners(listeners, pid)
  end

  defp find_name_in_listeners(listeners, pid) when is_list(listeners) or is_map(listeners) do
    Enum.find_value(listeners, &match_listener_pid(&1, pid))
  end

  defp find_name_in_listeners(_listeners, _pid), do: nil

  defp match_listener_pid({name, info}, pid) when is_map(info) do
    if Map.get(info, :pid) == pid, do: name
  end

  defp match_listener_pid({name, info}, pid) when is_list(info) do
    if Keyword.get(info, :pid) == pid, do: name
  end

  @doc """
  Get the server name for a given port.
  """
  def server_name_for_port(port), do: :"lmtp_server_#{port}"

  # gen_smtp_server_session callbacks

  @impl true
  def init(hostname, _session_count, _peer_address, _options) do
    banner = [hostname, " Custyard LMTP server ready"]
    {:ok, banner, %{from: nil, to: [], data: nil}}
  end

  @impl true
  def handle_HELO(hostname, state) do
    Logger.debug("LMTP HELO from #{hostname}")
    {:ok, state}
  end

  @impl true
  def handle_EHLO(hostname, extensions, state) do
    Logger.debug("LMTP EHLO from #{hostname}")
    # Return supported extensions
    {:ok, extensions, state}
  end

  @impl true
  def handle_MAIL(from, state) do
    Logger.debug("LMTP MAIL FROM: #{from}")
    {:ok, %{state | from: from}}
  end

  @impl true
  def handle_MAIL_extension(extension, state) do
    Logger.debug("LMTP MAIL extension: #{extension}")
    {:ok, state}
  end

  @impl true
  def handle_RCPT(to, state) do
    Logger.debug("LMTP RCPT TO: #{to}")
    {:ok, %{state | to: [to | state.to]}}
  end

  @impl true
  def handle_RCPT_extension(extension, state) do
    Logger.debug("LMTP RCPT extension: #{extension}")
    {:ok, state}
  end

  @impl true
  def handle_DATA(_from, _to, <<>>, state) do
    # Empty data
    {:error, "552 Empty message", state}
  end

  @impl true
  def handle_DATA(from, to, data, state) do
    Logger.debug("LMTP DATA received from #{from} to #{inspect(to)}, size: #{byte_size(data)}")

    case process_email(data) do
      :ok ->
        {:ok, "250 2.0.0 Message accepted", state}

      {:error, :temporary, reason} ->
        Logger.warning("LMTP temporary error: #{inspect(reason)}")
        {:error, "421 4.7.0 Temporary failure: #{inspect(reason)}", state}

      {:error, :permanent, reason} ->
        Logger.warning("LMTP permanent error: #{inspect(reason)}")
        {:error, "550 5.7.0 Permanent failure: #{inspect(reason)}", state}
    end
  end

  @impl true
  def handle_RSET(state) do
    {:ok, %{state | from: nil, to: [], data: nil}}
  end

  @impl true
  def handle_VRFY(_address, state) do
    {:error, "252 VRFY disabled", state}
  end

  @impl true
  def handle_other(verb, _args, state) do
    Logger.debug("LMTP unrecognized command: #{verb}")
    {:noreply, state}
  end

  @impl true
  def handle_AUTH(_type, _username, _password, state) do
    {:error, "503 AUTH not supported", state}
  end

  @impl true
  def handle_STARTTLS(state) do
    {:ok, state}
  end

  @impl true
  def handle_info(_info, state) do
    {:noreply, state}
  end

  @impl true
  def code_change(_old_vsn, state, _extra) do
    {:ok, state}
  end

  @impl true
  def terminate(reason, state) do
    Logger.debug("LMTP session terminated: #{inspect(reason)}")
    {:ok, reason, state}
  end

  # Internal functions

  defp process_email(raw_data) do
    with {:ok, parsed} <- Parser.parse(raw_data),
         {:ok, _conversation} <- Processor.process(parsed) do
      :ok
    else
      {:error, {:parse_failed, reason}} ->
        {:error, :permanent, {:parse_failed, reason}}

      {:error, :sender_not_found} ->
        # Unknown sender - could be temporary if we expect them to register
        {:error, :temporary, :sender_not_found}

      {:error, :organization_not_found} ->
        {:error, :permanent, :organization_not_found}

      {:error, reason} ->
        # Default to temporary for unknown errors (allows retry)
        {:error, :temporary, reason}
    end
  end
end
