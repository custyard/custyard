# credo:disable-for-this-file Credo.Check.Readability.FunctionNames
defmodule Custyard.Email.LMTPServer do
  @moduledoc """
  LMTP server for receiving emails from MTAs.

  Uses gen_smtp's server callback behavior to accept incoming mail.
  Parses raw RFC 5322 email and forwards to Processor for handling.

  Note: This module implements the :gen_smtp_server_session behaviour which
  requires callback names like handle_HELO, handle_DATA, etc. These names
  are dictated by the Erlang library and cannot be changed.

  ## Configuration

  Basic configuration (in config/runtime.exs):

      config :custyard, :lmtp,
        enabled: true,
        port: 2024,
        hostname: "localhost"

  ## STARTTLS Support

  To enable STARTTLS for encrypted connections, provide TLS certificate options:

      config :custyard, :lmtp,
        enabled: true,
        port: 2024,
        hostname: "localhost",
        tls: [
          certfile: "/path/to/cert.pem",
          keyfile: "/path/to/key.pem"
        ]

  The TLS options are passed directly to Erlang's ssl module. Common options:
  - `certfile` - Path to the server certificate file (PEM format)
  - `keyfile` - Path to the private key file (PEM format)
  - `cacertfile` - Path to CA certificates file (for client verification)
  - `verify` - Set to `:verify_peer` to require client certificates

  When TLS options are configured, STARTTLS will be advertised in EHLO responses.
  Note: If running behind a reverse proxy that handles TLS, STARTTLS is typically
  not needed at the LMTP level.

  ## Connection Limits

  For production tuning, configure connection limits:

      config :custyard, :lmtp,
        enabled: true,
        port: 2024,
        hostname: "localhost",
        max_connections: 1000,   # Max concurrent connections (default: 1024)
        num_acceptors: 10        # Number of acceptor processes (default: 10)

  - `max_connections` - Maximum number of concurrent LMTP connections.
    Use `:infinity` for no limit (not recommended in production).
  - `num_acceptors` - Number of acceptor processes listening for connections.
    More acceptors can handle higher connection rates. 10 is typically sufficient.

  ## Rate Limiting

  To protect against abuse from misconfigured or malicious senders, configure rate limits:

      config :custyard, :lmtp,
        enabled: true,
        port: 2024,
        hostname: "localhost",
        rate_limit: [
          messages_per_connection: 100,  # Max messages per connection (default: 100)
          messages_per_minute: 1000,     # Global max messages per minute (default: 1000)
          window_seconds: 60             # Rate limit window in seconds (default: 60)
        ]

  - `messages_per_connection` - Maximum messages a single connection can deliver.
    Set to `:infinity` to disable (not recommended).
  - `messages_per_minute` - Global rate limit across all connections.
    Set to `:infinity` to disable global rate limiting.
  - `window_seconds` - Time window for global rate limiting.

  When rate limits are exceeded, the server returns a 421 temporary error,
  allowing compliant MTAs to retry later.

  ## Mail Loop Detection

  To prevent mail loops (emails cycling through the system repeatedly), the server
  checks Received headers for its own hostname:

      config :custyard, :lmtp,
        enabled: true,
        port: 2024,
        hostname: "mail.example.com",
        max_received_count: 5  # Max times our hostname can appear (default: 3)

  When loop detection is triggered, the server returns a permanent 554 error
  to prevent further delivery attempts. The hostname configured here should
  match how the MTA identifies this server in Received headers.

  ## Message Size Limits

  To protect against oversized messages, configure the maximum message size:

      config :custyard, :lmtp,
        enabled: true,
        port: 2024,
        hostname: "localhost",
        max_message_size: 10_485_760  # 10 MB (default)

  - `max_message_size` - Maximum message size in bytes. The server advertises
    this limit via the SIZE extension (RFC 1870) in EHLO/LHLO responses, allowing
    MTAs to reject oversized messages before transmission begins.
    Set to `:infinity` to disable size checking (not recommended).

  When a message exceeds the limit:
  - If SIZE is specified in MAIL FROM, rejection happens immediately (552 error)
  - Otherwise, rejection happens after DATA is received

  ## Recipient Limits

  To prevent resource exhaustion from large recipient lists:

      config :custyard, :lmtp,
        enabled: true,
        port: 2024,
        hostname: "localhost",
        max_recipients: 100  # Max recipients per message (default: 100)

  - `max_recipients` - Maximum number of RCPT TO commands per message.
    When exceeded, the server returns a 452 temporary error.
    Set to `:infinity` to disable recipient limits (not recommended).

  ## IP Access Control

  By default, the LMTP server only accepts connections from localhost (127.0.0.1
  and ::1) for security. In a containerized deployment or when the MTA is on a
  different host, configure allowed IPs explicitly:

      config :custyard, :lmtp,
        enabled: true,
        port: 2024,
        hostname: "localhost",
        allowed_ips: [
          {127, 0, 0, 1},           # IPv4 localhost
          {0, 0, 0, 0, 0, 0, 0, 1}, # IPv6 localhost
          {10, 0, 0, 5}             # MTA host IP
        ]

  - `allowed_ips` - List of IP address tuples permitted to connect. Each IP must
    be an Erlang-style tuple (e.g., `{192, 168, 1, 100}` for IPv4 or
    `{0, 0, 0, 0, 0, 0, 0, 1}` for IPv6). Connections from non-allowed IPs are
    rejected immediately with a 554 error.

  To allow all IPs (not recommended for production):

      allowed_ips: :any

  ## Telemetry Events

  The LMTP server emits telemetry events for monitoring and metrics collection.
  Attach handlers using `:telemetry.attach/4` or `:telemetry.attach_many/4`.

  ### Connection Events

  - `[:custyard, :lmtp, :connection, :open]` - Emitted when a client connects
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{peer: tuple(), tls_enabled: boolean()}`

  - `[:custyard, :lmtp, :connection, :close]` - Emitted when a connection closes
    - Measurements: `%{duration: native_time()}`
    - Metadata: `%{peer: tuple(), reason: term(), messages_processed: integer()}`

  - `[:custyard, :lmtp, :connection, :rejected]` - Emitted when a connection is rejected
    - Measurements: `%{count: 1}`
    - Metadata: `%{peer: tuple(), reason: :ip_not_allowed}`

  ### Email Processing Events

  - `[:custyard, :lmtp, :email, :start]` - Emitted when email processing begins
    - Measurements: `%{system_time: integer()}`
    - Metadata: `%{size: integer(), from: binary(), to: list()}`

  - `[:custyard, :lmtp, :email, :stop]` - Emitted when email processing completes
    - Measurements: `%{duration: native_time()}`
    - Metadata: `%{size: integer(), from: binary(), to: list(), result: :ok | :error}`
    - On error, additional metadata: `%{error_type: :temporary | :permanent, reason: term()}`

  ### Rate Limit Events

  - `[:custyard, :lmtp, :rate_limit, :exceeded]` - Emitted when rate limits are hit
    - Measurements: `%{count: 1}`
    - Metadata: `%{limit_type: :connection | :global, peer: tuple()}`

  ### Example: Logging Handler

      :telemetry.attach_many(
        "lmtp-logger",
        [
          [:custyard, :lmtp, :email, :stop],
          [:custyard, :lmtp, :rate_limit, :exceeded]
        ],
        fn event, measurements, metadata, _config ->
          Logger.info("LMTP event", event: event, measurements: measurements, metadata: metadata)
        end,
        nil
      )
  """

  # Default rate limit configuration
  @default_messages_per_connection 100
  @default_messages_per_minute 1000
  @default_window_seconds 60

  # Default mail loop detection configuration
  # Number of times our hostname can appear in Received headers before rejection
  @default_max_received_count 3

  # Default maximum message size in bytes (10 MB)
  @default_max_message_size 10_485_760

  # Default maximum recipients per message
  @default_max_recipients 100

  # Default allowed IPs - localhost only for security
  # This restricts connections to local MTA unless explicitly configured otherwise
  @default_allowed_ips [{127, 0, 0, 1}, {0, 0, 0, 0, 0, 0, 0, 1}]

  # ETS table name for global rate limiting
  @rate_limit_table :lmtp_rate_limits

  # Telemetry event names
  # Use [:custyard, :lmtp, :email, :*] for span events (start/stop/exception)
  # Metrics can attach to [:custyard, :lmtp, :email, :stop] for durations
  @telemetry_prefix [:custyard, :lmtp, :email]

  require Logger

  @behaviour :gen_smtp_server_session

  alias Custyard.Email.Parser
  alias Custyard.InboundRoutes
  alias Custyard.Webhooks.Adapters.Email, as: EmailAdapter
  alias Custyard.Webhooks.Dispatcher

  # Client API

  @doc """
  Start the LMTP server under the supervision tree.
  Returns a child specification.
  """
  def child_spec(opts) do
    port = Keyword.get(opts, :port, 2024)
    hostname = Keyword.get(opts, :hostname, "localhost")
    tls_opts = Keyword.get(opts, :tls, [])
    max_connections = Keyword.get(opts, :max_connections, 1024)
    num_acceptors = Keyword.get(opts, :num_acceptors, 10)
    rate_limit = Keyword.get(opts, :rate_limit, [])
    allowed_ips = Keyword.get(opts, :allowed_ips, @default_allowed_ips)

    max_received_count =
      Keyword.get(opts, :max_received_count, @default_max_received_count)

    max_message_size = Keyword.get(opts, :max_message_size, @default_max_message_size)
    max_recipients = Keyword.get(opts, :max_recipients, @default_max_recipients)

    %{
      id: __MODULE__,
      start:
        {__MODULE__, :start_link,
         [
           [
             port: port,
             hostname: hostname,
             tls: tls_opts,
             max_connections: max_connections,
             num_acceptors: num_acceptors,
             rate_limit: rate_limit,
             max_received_count: max_received_count,
             max_message_size: max_message_size,
             max_recipients: max_recipients,
             allowed_ips: allowed_ips
           ]
         ]},
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
    tls_opts = Keyword.get(opts, :tls, [])
    max_connections = Keyword.get(opts, :max_connections, 1024)
    num_acceptors = Keyword.get(opts, :num_acceptors, 10)
    rate_limit = Keyword.get(opts, :rate_limit, [])
    allowed_ips = Keyword.get(opts, :allowed_ips, @default_allowed_ips)

    max_received_count =
      Keyword.get(opts, :max_received_count, @default_max_received_count)

    max_message_size = Keyword.get(opts, :max_message_size, @default_max_message_size)
    max_recipients = Keyword.get(opts, :max_recipients, @default_max_recipients)

    # Initialize rate limit ETS table if global rate limiting is enabled
    ensure_rate_limit_table()

    # Use a unique server name based on port to allow multiple instances (for testing)
    server_name = Keyword.get(opts, :name, server_name_for_port(port))

    # Build TLS options for gen_smtp if TLS is configured
    # gen_smtp expects certfile/keyfile as separate options or tls_options list
    session_opts =
      build_session_options(
        tls_opts,
        rate_limit,
        max_received_count,
        max_recipients,
        max_message_size,
        allowed_ips
      )

    # Ranch options for connection limits
    ranch_opts = %{
      max_connections: max_connections,
      num_acceptors: num_acceptors
    }

    # LMTP protocol option goes inside sessionoptions, not at the top level
    # The top-level protocol option is for transport (tcp/ssl)
    server_opts = [
      port: port,
      domain: hostname,
      sessionoptions: session_opts,
      ranch_opts: ranch_opts
    ]

    if tls_enabled?(tls_opts) do
      Logger.info("Starting LMTP server on port #{port} with STARTTLS support")
    else
      Logger.info("Starting LMTP server on port #{port}")
    end

    :gen_smtp_server.start(server_name, __MODULE__, server_opts)
  end

  defp build_session_options(
         tls_opts,
         rate_limit,
         max_received_count,
         max_recipients,
         max_message_size,
         allowed_ips
       ) do
    # Build rate limit config with defaults
    rate_limit_config = [
      messages_per_connection:
        Keyword.get(rate_limit, :messages_per_connection, @default_messages_per_connection),
      messages_per_minute:
        Keyword.get(rate_limit, :messages_per_minute, @default_messages_per_minute),
      window_seconds: Keyword.get(rate_limit, :window_seconds, @default_window_seconds)
    ]

    base_opts = [
      protocol: :lmtp,
      callbackoptions: [
        tls_enabled: tls_enabled?(tls_opts),
        rate_limit: rate_limit_config,
        max_received_count: max_received_count,
        max_recipients: max_recipients,
        max_message_size: max_message_size,
        allowed_ips: allowed_ips
      ]
    ]

    if tls_enabled?(tls_opts) do
      # Convert Elixir keyword list to erlang-compatible format
      # gen_smtp expects tls_options as a proplist
      tls_options =
        tls_opts
        |> Enum.map(fn
          {:certfile, path} -> {:certfile, to_charlist(path)}
          {:keyfile, path} -> {:keyfile, to_charlist(path)}
          {:cacertfile, path} -> {:cacertfile, to_charlist(path)}
          other -> other
        end)

      Keyword.put(base_opts, :tls_options, tls_options)
    else
      base_opts
    end
  end

  # Ensure the rate limit ETS table exists
  defp ensure_rate_limit_table do
    case :ets.whereis(@rate_limit_table) do
      :undefined ->
        :ets.new(@rate_limit_table, [:named_table, :public, :set, {:write_concurrency, true}])

      _tid ->
        :ok
    end
  end

  defp tls_enabled?(tls_opts) do
    # TLS requires both a certificate and its corresponding private key
    Keyword.has_key?(tls_opts, :certfile) and Keyword.has_key?(tls_opts, :keyfile)
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

  @doc """
  Clean up expired rate limit entries from the ETS table.

  This should be called periodically (e.g., by a scheduler) to prevent
  unbounded growth of the rate limit table during low-traffic periods.

  Returns the number of entries deleted, or 0 if the table doesn't exist.
  """
  @spec cleanup_rate_limits() :: non_neg_integer()
  def cleanup_rate_limits do
    cleanup_rate_limits(@default_window_seconds)
  end

  @doc """
  Clean up rate limit entries older than the specified window.
  """
  @spec cleanup_rate_limits(pos_integer()) :: non_neg_integer()
  def cleanup_rate_limits(window_seconds) do
    case :ets.whereis(@rate_limit_table) do
      :undefined ->
        0

      _tid ->
        now = System.system_time(:second)
        window_start = now - window_seconds

        try do
          :ets.foldl(
            fn
              {{:count, timestamp}, _count}, deleted when timestamp <= window_start ->
                :ets.delete(@rate_limit_table, {:count, timestamp})
                deleted + 1

              _, deleted ->
                deleted
            end,
            0,
            @rate_limit_table
          )
        rescue
          ArgumentError -> 0
        end
    end
  end

  # gen_smtp_server_session callbacks

  @impl true
  def init(hostname, _session_count, peer_address, options) do
    allowed_ips = Keyword.get(options, :allowed_ips, @default_allowed_ips)

    # Check IP access control before accepting connection
    if ip_allowed?(peer_address, allowed_ips) do
      init_accepted(hostname, peer_address, options)
    else
      Logger.warning("LMTP connection rejected: IP not in allowlist",
        peer: inspect(peer_address)
      )

      # Emit telemetry for rejected connections
      :telemetry.execute(
        [:custyard, :lmtp, :connection, :rejected],
        %{count: 1},
        %{peer: peer_address, reason: :ip_not_allowed}
      )

      {:stop, :normal, "554 5.7.1 Connection refused - IP not authorized"}
    end
  end

  defp init_accepted(hostname, peer_address, options) do
    banner = [hostname, " Custyard LMTP server ready"]
    tls_enabled = Keyword.get(options, :tls_enabled, false)
    rate_limit = Keyword.get(options, :rate_limit, [])

    max_received_count =
      Keyword.get(options, :max_received_count, @default_max_received_count)

    max_recipients = Keyword.get(options, :max_recipients, @default_max_recipients)
    max_message_size = Keyword.get(options, :max_message_size, @default_max_message_size)

    # Convert hostname to string for loop detection
    # gen_smtp passes it as a charlist
    hostname_string = if is_list(hostname), do: to_string(hostname), else: hostname

    # Emit connection opened telemetry event
    :telemetry.execute(
      [:custyard, :lmtp, :connection, :open],
      %{system_time: System.system_time()},
      %{peer: peer_address, tls_enabled: tls_enabled}
    )

    state = %{
      from: nil,
      to: [],
      data: nil,
      organization: nil,
      tls_enabled: tls_enabled,
      peer_address: peer_address,
      connected_at: System.monotonic_time(),
      # Loop detection config
      hostname: hostname_string,
      max_received_count: max_received_count,
      # Recipient limit
      max_recipients: max_recipients,
      # Message size limit (RFC 1870)
      max_message_size: max_message_size,
      declared_size: nil,
      # Rate limiting state
      message_count: 0,
      messages_per_connection:
        Keyword.get(rate_limit, :messages_per_connection, @default_messages_per_connection),
      messages_per_minute:
        Keyword.get(rate_limit, :messages_per_minute, @default_messages_per_minute),
      window_seconds: Keyword.get(rate_limit, :window_seconds, @default_window_seconds)
    }

    {:ok, banner, state}
  end

  # Check if peer IP is in the allowed list
  defp ip_allowed?(_peer_address, :any), do: true

  # gen_smtp may pass peer_address as {ip, port} tuple or just the IP tuple
  defp ip_allowed?({ip, port}, allowed_ips) when is_list(allowed_ips) and is_integer(port) do
    Enum.member?(allowed_ips, ip)
  end

  # Handle direct IP tuple (IPv4: 4-element, IPv6: 8-element)
  defp ip_allowed?(ip, allowed_ips)
       when is_list(allowed_ips) and is_tuple(ip) and tuple_size(ip) in [4, 8] do
    Enum.member?(allowed_ips, ip)
  end

  defp ip_allowed?(peer_address, allowed_ips) when is_list(allowed_ips) do
    # Fallback for unexpected peer_address formats
    Logger.debug("Unexpected peer_address format in ip_allowed?",
      peer: inspect(peer_address)
    )

    false
  end

  @impl true
  def handle_HELO(hostname, state) do
    Logger.debug("LMTP HELO received", client_hostname: hostname)
    {:ok, state}
  end

  @impl true
  def handle_EHLO(hostname, extensions, state) do
    Logger.debug("LMTP EHLO received", client_hostname: hostname)

    # Add STARTTLS extension if TLS is configured
    # gen_smtp will handle the actual TLS negotiation
    extensions =
      if Map.get(state, :tls_enabled, false) do
        # Add STARTTLS to the extensions list
        # gen_smtp expects {charlist, true} tuple format (Erlang strings)
        [{~c"STARTTLS", true} | extensions]
      else
        extensions
      end

    # Add SIZE extension (RFC 1870) if message size limit is configured
    # gen_smtp expects {charlist, charlist_value} for extensions with values
    extensions =
      case Map.get(state, :max_message_size) do
        nil -> extensions
        :infinity -> extensions
        size when is_integer(size) -> [{~c"SIZE", Integer.to_charlist(size)} | extensions]
      end

    {:ok, extensions, state}
  end

  @impl true
  def handle_MAIL(from, state) do
    Logger.debug("LMTP MAIL FROM received", sender: from)
    {:ok, %{state | from: from}}
  end

  @impl true
  def handle_MAIL_extension(extension, state) do
    Logger.debug("LMTP MAIL extension received", extension: extension)
    handle_mail_extension_impl(extension, state)
  end

  # Handle SIZE extension (RFC 1870)
  defp handle_mail_extension_impl("SIZE=" <> size_str, state) do
    case Integer.parse(size_str) do
      {declared_size, ""} ->
        max_size = Map.get(state, :max_message_size, @default_max_message_size)

        cond do
          max_size == :infinity ->
            {:ok, %{state | declared_size: declared_size}}

          declared_size > max_size ->
            Logger.warning("LMTP rejecting oversized message",
              declared_size: declared_size,
              max_size: max_size,
              sender: state[:from]
            )

            {:error, "552 5.3.4 Message size exceeds fixed maximum message size", state}

          true ->
            {:ok, %{state | declared_size: declared_size}}
        end

      _ ->
        # Invalid SIZE parameter, ignore it
        {:ok, state}
    end
  end

  # Ignore other extensions
  defp handle_mail_extension_impl(_extension, state) do
    {:ok, state}
  end

  @impl true
  def handle_RCPT(to, state) do
    Logger.debug("LMTP RCPT TO received", recipient: to)
    current_count = length(state.to)
    max_recipients = Map.get(state, :max_recipients, @default_max_recipients)

    # Validate recipient domain and resolve organization before accepting
    case validate_recipient_domain(to) do
      {:ok, org} ->
        cond do
          max_recipients == :infinity ->
            {:ok, %{state | to: [to | state.to], organization: org}}

          current_count < max_recipients ->
            {:ok, %{state | to: [to | state.to], organization: org}}

          true ->
            # Emit telemetry for recipient limit exceeded
            :telemetry.execute(
              [:custyard, :lmtp, :recipient_limit, :exceeded],
              %{count: 1},
              %{peer: state[:peer_address], current_count: current_count, max: max_recipients}
            )

            Logger.warning("LMTP recipient limit exceeded",
              current_count: current_count,
              max_recipients: max_recipients,
              sender: state[:from]
            )

            {:error, "452 4.5.3 Too many recipients", state}
        end

      {:error, :invalid_domain} ->
        Logger.warning("LMTP rejecting unknown recipient domain",
          recipient: to,
          sender: state[:from]
        )

        {:error, "550 5.1.1 Unknown recipient domain", state}
    end
  end

  # Validate that the recipient domain is one we serve and resolve the org.
  # Returns {:ok, org} or {:error, :invalid_domain}.
  defp validate_recipient_domain(recipient) when is_binary(recipient) do
    case extract_domain(recipient) do
      nil ->
        {:error, :invalid_domain}

      domain ->
        case find_org_by_domain(domain) do
          {:ok, org} -> {:ok, org}
          :not_found -> {:error, :invalid_domain}
        end
    end
  end

  defp validate_recipient_domain(_), do: {:error, :invalid_domain}

  defp extract_domain(email) do
    case String.split(to_string(email), "@") do
      [_, domain] -> String.downcase(domain)
      _ -> nil
    end
  end

  # Look up organization by domain (matches domain or custom_domain).
  # Returns {:ok, org} or :not_found.
  defp find_org_by_domain(domain) do
    import Ecto.Query

    query =
      from(o in Custyard.Organization,
        where: o.domain == ^domain or o.custom_domain == ^domain,
        limit: 1
      )

    case Custyard.Repo.one(query) do
      nil -> :not_found
      org -> {:ok, org}
    end
  end


  @impl true
  def handle_RCPT_extension(extension, state) do
    Logger.debug("LMTP RCPT extension received", extension: extension)
    {:ok, state}
  end

  @impl true
  def handle_DATA(_from, _to, <<>>, state) do
    # Empty data
    {:error, "552 Empty message", state}
  end

  @impl true
  def handle_DATA(from, to, data, state) do
    data_size = byte_size(data)
    recipient_count = length(to)

    Logger.info("LMTP DATA received",
      sender: from,
      recipient_count: recipient_count,
      size_bytes: data_size
    )

    with :ok <- check_message_size(data_size, state),
         :ok <- check_mail_loop(data, state),
         :ok <- check_rate_limits(state) do
      process_and_respond(data, state)
    else
      {:error, :message_too_large, actual_size, max_size} ->
        Logger.warning("LMTP message too large",
          actual_size: actual_size,
          max_size: max_size,
          sender: state[:from]
        )

        {:error, "552 5.3.4 Message size exceeds fixed maximum message size", state}

      {:error, :mail_loop, count} ->
        :telemetry.execute(
          [:custyard, :lmtp, :mail_loop, :detected],
          %{count: count},
          %{hostname: state[:hostname], peer: state[:peer_address]}
        )

        Logger.warning("LMTP mail loop detected",
          hostname: state[:hostname],
          received_count: count,
          sender: state[:from]
        )

        {:error, "554 5.4.6 Mail loop detected", state}

      {:error, :connection_limit} ->
        :telemetry.execute(
          [:custyard, :lmtp, :rate_limit, :exceeded],
          %{count: 1},
          %{limit_type: :connection, peer: state[:peer_address]}
        )

        Logger.warning("LMTP rate limit exceeded",
          limit_type: :connection,
          message_count: state[:message_count],
          sender: state[:from]
        )

        {:error, "421 4.7.1 Too many messages on this connection", state}

      {:error, :global_limit} ->
        :telemetry.execute(
          [:custyard, :lmtp, :rate_limit, :exceeded],
          %{count: 1},
          %{limit_type: :global, peer: state[:peer_address]}
        )

        Logger.warning("LMTP rate limit exceeded",
          limit_type: :global,
          sender: state[:from]
        )

        {:error, "421 4.7.1 Server busy, try again later", state}
    end
  end

  defp process_and_respond(data, state) do
    metadata = %{
      size: byte_size(data),
      from: state[:from],
      to: state[:to]
    }

    start_time = System.monotonic_time()

    # Emit start event
    :telemetry.execute(
      @telemetry_prefix ++ [:start],
      %{system_time: System.system_time()},
      metadata
    )

    case process_email(data, state) do
      :ok ->
        # Emit stop event with duration
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          @telemetry_prefix ++ [:stop],
          %{duration: duration},
          Map.put(metadata, :result, :ok)
        )

        # Increment counters after successful processing
        new_state = increment_message_count(state)
        record_global_message()
        {:ok, "250 2.0.0 Message accepted", new_state}

      {:error, error_type, reason} ->
        # Emit stop event with error info
        duration = System.monotonic_time() - start_time

        :telemetry.execute(
          @telemetry_prefix ++ [:stop],
          %{duration: duration},
          Map.merge(metadata, %{result: :error, error_type: error_type, reason: reason})
        )

        case error_type do
          :temporary ->
            Logger.warning("LMTP temporary processing error",
              error_type: :temporary,
              reason: inspect(reason),
              sender: state[:from]
            )

            {:error, "421 4.7.0 Temporary failure, try again later", state}

          :permanent ->
            Logger.warning("LMTP permanent processing error",
              error_type: :permanent,
              reason: inspect(reason),
              sender: state[:from]
            )

            {:error, "550 5.7.0 Permanent failure", state}
        end
    end
  end

  @impl true
  def handle_RSET(state) do
    {:ok, %{state | from: nil, to: [], data: nil, declared_size: nil, organization: nil}}
  end

  @impl true
  def handle_VRFY(_address, state) do
    {:error, "252 VRFY disabled", state}
  end

  @impl true
  def handle_other(verb, _args, state) do
    Logger.warning("LMTP unrecognized command received", command: verb)
    {:noreply, state}
  end

  @impl true
  def handle_AUTH(_type, _username, _password, state) do
    {:error, "503 AUTH not supported", state}
  end

  @impl true
  def handle_STARTTLS(state) do
    # This callback is invoked AFTER TLS negotiation succeeds
    # gen_smtp handles the actual TLS handshake; we just receive notification
    Logger.info("LMTP STARTTLS negotiation completed", peer: inspect(state[:peer_address]))
    state
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
    # Calculate connection duration
    duration =
      case Map.get(state, :connected_at) do
        nil -> 0
        connected_at -> System.monotonic_time() - connected_at
      end

    # Emit connection closed telemetry event
    :telemetry.execute(
      [:custyard, :lmtp, :connection, :close],
      %{duration: duration},
      %{
        peer: Map.get(state, :peer_address),
        reason: reason,
        messages_processed: Map.get(state, :message_count, 0)
      }
    )

    Logger.debug("LMTP session terminated",
      reason: inspect(reason),
      messages_processed: Map.get(state, :message_count, 0)
    )

    {:ok, reason, state}
  end

  # Internal functions

  defp process_email(raw_data, state) do
    org = state[:organization]

    with {:ok, parsed} <- Parser.parse(raw_data),
         {:ok, normalized} <- EmailAdapter.normalize(parsed),
         {:ok, route} <- resolve_route(org),
         {:ok, _conversation} <- Dispatcher.dispatch(route, normalized) do
      :ok
    else
      {:error, {:parse_failed, reason}} ->
        {:error, :permanent, {:parse_failed, reason}}

      {:error, :sender_not_found} ->
        # Unknown sender - could be temporary if we expect them to register
        {:error, :temporary, :sender_not_found}

      {:error, :organization_not_found} ->
        {:error, :permanent, :organization_not_found}

      {:error, :no_organization} ->
        {:error, :permanent, :no_organization}

      {:error, reason} ->
        # Default to temporary for unknown errors (allows retry)
        {:error, :temporary, reason}
    end
  end

  # Resolve the inbound route for an organization, creating one if needed.
  # find_or_create_general_route calls Lettermint API as a side-effect when
  # creating a new route — acceptable here because it only happens once per org.
  defp resolve_route(nil), do: {:error, :no_organization}

  defp resolve_route(org) do
    case InboundRoutes.get_general_route(org.id) do
      nil ->
        # Side-effect: calls Lettermint API to create remote route
        InboundRoutes.find_or_create_general_route(org.id)

      route ->
        {:ok, route}
    end
  end

  # Mail loop detection functions

  defp check_mail_loop(data, state) do
    hostname = Map.get(state, :hostname, "")
    max_count = Map.get(state, :max_received_count, @default_max_received_count)

    # Skip loop detection if hostname is empty or max_count is :infinity
    cond do
      hostname == "" or hostname == nil ->
        :ok

      max_count == :infinity ->
        :ok

      true ->
        # Count occurrences of hostname in Received headers
        count = count_received_occurrences(data, hostname)

        if count > max_count do
          {:error, :mail_loop, count}
        else
          :ok
        end
    end
  end

  # Count how many times our hostname appears in Received headers
  # Received headers format (RFC 5321):
  # Received: from mail.example.com by ourserver.example.com; timestamp
  defp count_received_occurrences(data, hostname) when is_binary(data) do
    # Extract all Received headers by finding lines starting with "Received:"
    # Email headers end at first blank line (CRLF CRLF or just \n\n)
    headers_section =
      case :binary.split(data, "\r\n\r\n") do
        [headers, _body] ->
          headers

        [all] ->
          case :binary.split(all, "\n\n") do
            [headers, _body] -> headers
            [all2] -> all2
          end
      end

    # RFC 5322 allows header folding (continuation lines start with whitespace)
    # Unfold headers before processing
    unfolded =
      headers_section
      |> String.replace(~r/\r?\n[\t ]+/, " ")

    # Find all Received header lines
    received_headers =
      unfolded
      |> String.split(~r/\r?\n/)
      |> Enum.filter(&String.starts_with?(&1, "Received:"))

    # Count occurrences of our hostname in Received headers
    # Match case-insensitively as hostnames are not case-sensitive
    hostname_pattern = Regex.compile!(Regex.escape(hostname), [:caseless])

    Enum.count(received_headers, fn header ->
      Regex.match?(hostname_pattern, header)
    end)
  end

  defp count_received_occurrences(_data, _hostname), do: 0

  # Message size checking (RFC 1870)

  defp check_message_size(actual_size, state) do
    max_size = Map.get(state, :max_message_size, @default_max_message_size)

    cond do
      max_size == :infinity ->
        :ok

      actual_size <= max_size ->
        :ok

      true ->
        {:error, :message_too_large, actual_size, max_size}
    end
  end

  # Rate limiting functions

  defp check_rate_limits(state) do
    with :ok <- check_connection_limit(state) do
      check_global_limit(state)
    end
  end

  defp check_connection_limit(%{message_count: count, messages_per_connection: limit}) do
    cond do
      limit == :infinity -> :ok
      count < limit -> :ok
      true -> {:error, :connection_limit}
    end
  end

  defp check_global_limit(%{messages_per_minute: limit, window_seconds: window}) do
    if limit == :infinity do
      # Still clean up old entries periodically even when rate limiting is disabled
      # This prevents unbounded ETS table growth
      maybe_cleanup_stale_entries(window)
      :ok
    else
      current_count = get_global_message_count(window)

      if current_count < limit do
        :ok
      else
        {:error, :global_limit}
      end
    end
  end

  # Clean up stale entries approximately every 100 messages to avoid memory leak
  # when rate limiting is disabled (limit == :infinity)
  defp maybe_cleanup_stale_entries(window_seconds) do
    # Only clean up 1% of the time to avoid overhead
    if :rand.uniform(100) == 1 do
      now = System.system_time(:second)
      window_start = now - window_seconds

      try do
        :ets.foldl(
          fn
            {{:count, timestamp}, _count}, acc when timestamp <= window_start ->
              :ets.delete(@rate_limit_table, {:count, timestamp})
              acc

            _, acc ->
              acc
          end,
          :ok,
          @rate_limit_table
        )
      rescue
        ArgumentError -> :ok
      end
    end
  end

  defp increment_message_count(%{message_count: count} = state) do
    %{state | message_count: count + 1}
  end

  defp record_global_message do
    # Get the current time bucket (truncated to window start)
    # We use a simple approach: store counts per second and sum them
    now = System.system_time(:second)

    # Increment the counter for the current second
    try do
      :ets.update_counter(@rate_limit_table, {:count, now}, {2, 1}, {{:count, now}, 0})
    rescue
      ArgumentError ->
        # Table might not exist or be owned by another process
        # In this case, skip global rate limiting
        :ok
    end
  end

  defp get_global_message_count(window_seconds) do
    now = System.system_time(:second)
    window_start = now - window_seconds

    try do
      # Sum all counts within the window
      :ets.foldl(
        fn
          {{:count, timestamp}, count}, acc when timestamp > window_start ->
            acc + count

          {{:count, timestamp}, _count}, acc ->
            # Clean up old entries while we're iterating
            :ets.delete(@rate_limit_table, {:count, timestamp})
            acc

          _, acc ->
            acc
        end,
        0,
        @rate_limit_table
      )
    rescue
      ArgumentError ->
        # Table doesn't exist, return 0
        0
    end
  end
end
