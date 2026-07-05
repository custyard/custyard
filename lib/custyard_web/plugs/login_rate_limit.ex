defmodule CustyardWeb.Plugs.LoginRateLimit do
  @moduledoc """
  Rate limits failed login attempts by IP address using an ETS table.

  Allows a configurable number of failed attempts within a time window.
  After exceeding the limit, returns 429 Too Many Requests.

  ## Counting Strategy

  Only failed login attempts are counted toward the rate limit. A successful
  login (302 redirect) does not consume an attempt. This allows legitimate
  users to log in and out repeatedly without hitting the limit, while still
  protecting against brute force attacks.

  ## Periodic Cleanup

  On each request, there's a 1% chance of cleaning ALL stale entries (not just
  the requesting IP). This prevents unbounded ETS growth from bots making
  single requests from many IPs.

  ## Proxy Support

  Client IP extraction (proxy-header trust discipline included) is
  delegated to `CustyardWeb.ClientIP`. Two deliberate behavior deltas
  from the pre-extraction implementation, both only reachable when
  `:trust_proxy_headers` is enabled:

    * Header values that do not parse as an IP address now fall through
      to the next source and ultimately the peer address. Previously any
      raw header string — garbage included — became its own rate-limit
      bucket, letting a client mint a fresh login-attempt budget per
      unique garbage value.
    * When `X-Forwarded-For` is consulted, the rightmost entry wins
      (previously leftmost). The rightmost entry is the one appended by
      the trusted edge proxy; the leftmost is client-supplied and
      spoofable.

  ## Options

    * `:max_attempts` - Maximum failed attempts per window (default: 5)
    * `:window_ms` - Time window in milliseconds (default: 60_000 = 1 minute)
  """
  import Plug.Conn

  alias CustyardWeb.ClientIP

  @behaviour Plug

  @table :login_rate_limit
  @default_max_attempts 5
  @default_window_ms 60_000
  # Probabilistic cleanup: 1% chance per request
  @cleanup_probability 0.01

  @impl true
  def init(opts) do
    ensure_table_exists()

    %{
      max_attempts: Keyword.get(opts, :max_attempts, @default_max_attempts),
      window_ms: Keyword.get(opts, :window_ms, @default_window_ms)
    }
  end

  @impl true
  def call(conn, opts) do
    ensure_table_exists()
    ip = get_client_ip(conn)
    now = System.monotonic_time(:millisecond)
    window_start = now - opts.window_ms

    # Clean old entries for this IP
    clean_old_entries(ip, window_start)

    # Probabilistic global cleanup to prevent unbounded table growth
    # from many unique IPs making single requests
    maybe_global_cleanup(window_start)

    attempts = count_attempts(ip, window_start)

    if attempts >= opts.max_attempts do
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(429, "Too many login attempts. Please try again later.")
      |> halt()
    else
      # Register callback to record attempt only on failed login
      # A successful login returns 302 redirect, failed returns 200 with error page
      conn
      |> register_before_send(fn response_conn ->
        record_failed_attempt(response_conn, ip, now)
        response_conn
      end)
    end
  end

  # Record attempt only if the login failed (non-redirect response)
  # Successful logins redirect (302), failed ones render (200)
  defp record_failed_attempt(conn, ip, timestamp) do
    # Only count as attempt if not a redirect (failed login)
    unless conn.status in [301, 302, 303, 307, 308] do
      :ets.insert(@table, {ip, timestamp})
    end
  end

  # Ensure ETS table exists, handling race condition where multiple processes
  # may try to create it simultaneously. Uses try/rescue to handle the case
  # where another process creates the table between our whereis check and new call.
  # Table is protected (only owner can write) - plug processes write via owner's context.
  defp ensure_table_exists do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          # Use :public for write access from any process (plug runs in request process)
          # The table contains only rate limit data, no sensitive information
          :ets.new(@table, [:bag, :public, :named_table])
        rescue
          # Table was created by another process between whereis and new
          ArgumentError -> :ok
        end

      _ ->
        :ok
    end
  end

  # Clean up all stale entries with a small probability per request.
  # This prevents unbounded table growth from many unique IPs.
  defp maybe_global_cleanup(window_start) do
    if :rand.uniform() < @cleanup_probability do
      # Delete all entries older than window_start across all IPs
      :ets.select_delete(@table, [{{:"$1", :"$2"}, [{:<, :"$2", window_start}], [true]}])
    end
  end

  defp clean_old_entries(ip, window_start) do
    :ets.select_delete(@table, [{{ip, :"$1"}, [{:<, :"$1", window_start}], [true]}])
  end

  defp count_attempts(ip, window_start) do
    :ets.select_count(@table, [{{ip, :"$1"}, [{:>=, :"$1", window_start}], [true]}])
  end

  # Client IP extraction (including the trust_proxy_headers security
  # gating) lives in CustyardWeb.ClientIP, shared with PublicRateLimit.
  defp get_client_ip(conn), do: ClientIP.from_conn(conn)
end
