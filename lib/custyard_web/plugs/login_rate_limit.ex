defmodule CustyardWeb.Plugs.LoginRateLimit do
  @moduledoc """
  Rate limits login attempts by IP address using an ETS table.

  Allows a configurable number of attempts within a time window.
  After exceeding the limit, returns 429 Too Many Requests.

  Options:
    * `:max_attempts` - Maximum attempts per window (default: 5)
    * `:window_ms` - Time window in milliseconds (default: 60_000 = 1 minute)
  """
  import Plug.Conn

  @behaviour Plug

  @table :login_rate_limit
  @default_max_attempts 5
  @default_window_ms 60_000

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
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()
    now = System.monotonic_time(:millisecond)
    window_start = now - opts.window_ms

    # Clean old entries and count recent attempts for this IP
    clean_old_entries(ip, window_start)
    attempts = count_attempts(ip, window_start)

    if attempts >= opts.max_attempts do
      conn
      |> put_resp_content_type("text/html")
      |> send_resp(429, "Too many login attempts. Please try again later.")
      |> halt()
    else
      # Record this attempt
      :ets.insert(@table, {ip, now})
      conn
    end
  end

  defp ensure_table_exists do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:bag, :public, :named_table])

      _ ->
        :ok
    end
  end

  defp clean_old_entries(ip, window_start) do
    :ets.select_delete(@table, [{{ip, :"$1"}, [{:<, :"$1", window_start}], [true]}])
  end

  defp count_attempts(ip, window_start) do
    :ets.select_count(@table, [{{ip, :"$1"}, [{:>=, :"$1", window_start}], [true]}])
  end
end
