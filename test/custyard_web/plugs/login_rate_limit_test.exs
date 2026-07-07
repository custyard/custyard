defmodule CustyardWeb.Plugs.LoginRateLimitTest do
  use Custyard.DataCase, async: false

  import Plug.Conn
  import Plug.Test

  alias CustyardWeb.Plugs.LoginRateLimit

  @table :login_rate_limit

  setup do
    # Clear the ETS table before each test
    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    :ok
  end

  describe "init/1" do
    test "uses default values when no options provided" do
      opts = LoginRateLimit.init([])

      assert opts.max_attempts == 5
      assert opts.window_ms == 60_000
    end

    test "allows overriding max_attempts" do
      opts = LoginRateLimit.init(max_attempts: 10)

      assert opts.max_attempts == 10
    end

    test "allows overriding window_ms" do
      opts = LoginRateLimit.init(window_ms: 120_000)

      assert opts.window_ms == 120_000
    end

    test "allows overriding both options" do
      opts = LoginRateLimit.init(max_attempts: 3, window_ms: 30_000)

      assert opts.max_attempts == 3
      assert opts.window_ms == 30_000
    end
  end

  describe "call/2 rate limiting" do
    test "allows requests under the limit" do
      opts = LoginRateLimit.init(max_attempts: 3)
      conn = build_conn()

      result = LoginRateLimit.call(conn, opts)

      refute result.halted
      refute result.status == 429
    end

    test "blocks requests after exceeding the limit" do
      opts = LoginRateLimit.init(max_attempts: 3, window_ms: 60_000)
      conn = build_conn()

      # Simulate 3 previous failed attempts
      now = System.monotonic_time(:millisecond)
      ip = "127.0.0.1"

      :ets.insert(@table, {ip, now})
      :ets.insert(@table, {ip, now - 1000})
      :ets.insert(@table, {ip, now - 2000})

      result = LoginRateLimit.call(conn, opts)

      assert result.halted
      assert result.status == 429
      assert result.resp_body =~ "Too many login attempts"
    end

    test "allows requests after window expires" do
      opts = LoginRateLimit.init(max_attempts: 3, window_ms: 1000)
      conn = build_conn()
      ip = "127.0.0.1"

      # Insert old attempts outside the window
      old_time = System.monotonic_time(:millisecond) - 2000

      :ets.insert(@table, {ip, old_time})
      :ets.insert(@table, {ip, old_time - 100})
      :ets.insert(@table, {ip, old_time - 200})

      result = LoginRateLimit.call(conn, opts)

      refute result.halted
    end
  end

  describe "failed attempt counting" do
    test "records attempt on non-redirect response" do
      opts = LoginRateLimit.init(max_attempts: 10)
      conn = build_conn()
      ip = "127.0.0.1"

      # Clear any existing entries
      :ets.delete_all_objects(@table)

      # Call the plug
      result = LoginRateLimit.call(conn, opts)

      # Trigger the before_send callback by sending a non-redirect response
      result
      |> put_resp_content_type("text/html")
      |> send_resp(200, "Login failed")

      # Check that an attempt was recorded
      count = :ets.select_count(@table, [{{ip, :"$1"}, [], [true]}])
      assert count == 1
    end

    test "does not record attempt on redirect response (successful login)" do
      opts = LoginRateLimit.init(max_attempts: 10)
      conn = build_conn()
      ip = "127.0.0.1"

      # Clear any existing entries
      :ets.delete_all_objects(@table)

      # Call the plug
      result = LoginRateLimit.call(conn, opts)

      # Trigger the before_send callback with a redirect (successful login)
      result
      |> put_resp_header("location", "/dashboard")
      |> send_resp(302, "")

      # Check that no attempt was recorded
      count = :ets.select_count(@table, [{{ip, :"$1"}, [], [true]}])
      assert count == 0
    end

    test "does not record attempt for 301 redirect" do
      opts = LoginRateLimit.init(max_attempts: 10)
      conn = build_conn()
      ip = "127.0.0.1"

      :ets.delete_all_objects(@table)

      result = LoginRateLimit.call(conn, opts)
      result |> send_resp(301, "")

      count = :ets.select_count(@table, [{{ip, :"$1"}, [], [true]}])
      assert count == 0
    end

    test "does not record attempt for 303 redirect" do
      opts = LoginRateLimit.init(max_attempts: 10)
      conn = build_conn()
      ip = "127.0.0.1"

      :ets.delete_all_objects(@table)

      result = LoginRateLimit.call(conn, opts)
      result |> send_resp(303, "")

      count = :ets.select_count(@table, [{{ip, :"$1"}, [], [true]}])
      assert count == 0
    end
  end

  describe "IP extraction" do
    setup do
      # Enable proxy header trust for these tests
      Application.put_env(:custyard, :trust_proxy_headers, true)

      on_exit(fn ->
        Application.delete_env(:custyard, :trust_proxy_headers)
      end)

      :ok
    end

    test "extracts IP from Fly-Client-IP header" do
      opts = LoginRateLimit.init(max_attempts: 3, window_ms: 60_000)
      fly_ip = "203.0.113.42"

      # Insert attempts for the Fly IP
      now = System.monotonic_time(:millisecond)

      :ets.insert(@table, {fly_ip, now})
      :ets.insert(@table, {fly_ip, now - 1000})
      :ets.insert(@table, {fly_ip, now - 2000})

      conn =
        conn(:get, "/")
        |> put_req_header("fly-client-ip", fly_ip)

      result = LoginRateLimit.call(conn, opts)

      # Should be blocked because the Fly IP has 3 attempts
      assert result.halted
      assert result.status == 429
    end

    test "extracts IP from X-Forwarded-For header" do
      opts = LoginRateLimit.init(max_attempts: 3, window_ms: 60_000)
      client_ip = "198.51.100.10"

      # Insert attempts for the forwarded IP
      now = System.monotonic_time(:millisecond)

      :ets.insert(@table, {client_ip, now})
      :ets.insert(@table, {client_ip, now - 1000})
      :ets.insert(@table, {client_ip, now - 2000})

      conn =
        conn(:get, "/")
        |> put_req_header("x-forwarded-for", "10.0.0.1, 10.0.0.2, #{client_ip}")

      result = LoginRateLimit.call(conn, opts)

      # Should be blocked because the forwarded IP has 3 attempts
      assert result.halted
      assert result.status == 429
    end

    test "uses the rightmost (proxy-appended) IP from X-Forwarded-For" do
      opts = LoginRateLimit.init(max_attempts: 3, window_ms: 60_000)
      spoofed_ip = "192.0.2.50"
      real_ip = "198.51.100.77"

      # Insert attempts only for the client-supplied leftmost entry
      now = System.monotonic_time(:millisecond)

      :ets.insert(@table, {spoofed_ip, now})
      :ets.insert(@table, {spoofed_ip, now - 1000})
      :ets.insert(@table, {spoofed_ip, now - 2000})

      conn =
        conn(:get, "/")
        |> put_req_header("x-forwarded-for", "#{spoofed_ip}, #{real_ip}")

      result = LoginRateLimit.call(conn, opts)

      # Should NOT be blocked: the key is the rightmost entry (appended
      # by the trusted proxy), not the spoofable leftmost one
      refute result.halted
    end

    test "garbage header values key as the peer address, not a fresh bucket" do
      opts = LoginRateLimit.init(max_attempts: 3, window_ms: 60_000)
      peer_ip = "127.0.0.1"

      # Exhaust the peer's budget
      now = System.monotonic_time(:millisecond)

      :ets.insert(@table, {peer_ip, now})
      :ets.insert(@table, {peer_ip, now - 1000})
      :ets.insert(@table, {peer_ip, now - 2000})

      # Pre-extraction behavior keyed the raw header string, so every
      # unique garbage value minted a fresh login-attempt budget. Now
      # non-IP values fall through to the peer address.
      conn =
        conn(:get, "/")
        |> put_req_header("fly-client-ip", "garbage")
        |> put_req_header("x-forwarded-for", "also;;garbage")

      result = LoginRateLimit.call(conn, opts)

      assert result.halted
      assert result.status == 429
    end

    test "prefers Fly-Client-IP over X-Forwarded-For" do
      opts = LoginRateLimit.init(max_attempts: 3, window_ms: 60_000)
      fly_ip = "203.0.113.100"
      xff_ip = "198.51.100.200"

      # Insert attempts for X-Forwarded-For IP, but not Fly IP
      now = System.monotonic_time(:millisecond)

      :ets.insert(@table, {xff_ip, now})
      :ets.insert(@table, {xff_ip, now - 1000})
      :ets.insert(@table, {xff_ip, now - 2000})

      conn =
        conn(:get, "/")
        |> put_req_header("fly-client-ip", fly_ip)
        |> put_req_header("x-forwarded-for", xff_ip)

      result = LoginRateLimit.call(conn, opts)

      # Should NOT be blocked because Fly IP takes precedence and has no attempts
      refute result.halted
    end

    test "falls back to remote_ip when no proxy headers" do
      opts = LoginRateLimit.init(max_attempts: 3, window_ms: 60_000)
      ip = "127.0.0.1"

      # Insert attempts for the default IP
      now = System.monotonic_time(:millisecond)

      :ets.insert(@table, {ip, now})
      :ets.insert(@table, {ip, now - 1000})
      :ets.insert(@table, {ip, now - 2000})

      conn = conn(:get, "/")

      result = LoginRateLimit.call(conn, opts)

      # Should be blocked because remote_ip (127.0.0.1) has 3 attempts
      assert result.halted
      assert result.status == 429
    end

    test "trims whitespace from Fly-Client-IP" do
      opts = LoginRateLimit.init(max_attempts: 3, window_ms: 60_000)
      fly_ip = "203.0.113.42"

      now = System.monotonic_time(:millisecond)

      :ets.insert(@table, {fly_ip, now})
      :ets.insert(@table, {fly_ip, now - 1000})
      :ets.insert(@table, {fly_ip, now - 2000})

      conn =
        conn(:get, "/")
        |> put_req_header("fly-client-ip", "  #{fly_ip}  ")

      result = LoginRateLimit.call(conn, opts)

      assert result.halted
    end

    test "trims whitespace from X-Forwarded-For entries" do
      opts = LoginRateLimit.init(max_attempts: 3, window_ms: 60_000)
      client_ip = "198.51.100.10"

      now = System.monotonic_time(:millisecond)

      :ets.insert(@table, {client_ip, now})
      :ets.insert(@table, {client_ip, now - 1000})
      :ets.insert(@table, {client_ip, now - 2000})

      conn =
        conn(:get, "/")
        |> put_req_header("x-forwarded-for", "10.0.0.1,   #{client_ip}  ")

      result = LoginRateLimit.call(conn, opts)

      assert result.halted
    end
  end

  describe "IP extraction security" do
    test "ignores proxy headers when trust_proxy_headers is false (default)" do
      # Ensure trust_proxy_headers is false (the secure default)
      Application.delete_env(:custyard, :trust_proxy_headers)

      opts = LoginRateLimit.init(max_attempts: 3, window_ms: 60_000)
      spoofed_ip = "198.51.100.10"
      real_ip = "127.0.0.1"

      # Insert attempts for the spoofed IP (from X-Forwarded-For)
      now = System.monotonic_time(:millisecond)

      :ets.insert(@table, {spoofed_ip, now})
      :ets.insert(@table, {spoofed_ip, now - 1000})
      :ets.insert(@table, {spoofed_ip, now - 2000})

      # Attacker sends fake X-Forwarded-For header trying to get blocked
      # (or more commonly, to bypass rate limit by pretending to be a different IP)
      conn =
        conn(:get, "/")
        |> put_req_header("x-forwarded-for", spoofed_ip)

      result = LoginRateLimit.call(conn, opts)

      # Should NOT be blocked because proxy headers are ignored,
      # real IP (127.0.0.1 from conn) has no attempts
      refute result.halted

      # Now verify blocking works on the real IP
      :ets.insert(@table, {real_ip, now})
      :ets.insert(@table, {real_ip, now - 1000})
      :ets.insert(@table, {real_ip, now - 2000})

      result2 = LoginRateLimit.call(conn(:get, "/"), opts)
      assert result2.halted
    end
  end

  describe "cleanup" do
    test "cleans old entries for the requesting IP" do
      opts = LoginRateLimit.init(max_attempts: 10, window_ms: 1000)
      ip = "127.0.0.1"

      # Insert old entries
      old_time = System.monotonic_time(:millisecond) - 5000

      :ets.insert(@table, {ip, old_time})
      :ets.insert(@table, {ip, old_time - 100})

      # Call the plug (cleanup happens during call)
      LoginRateLimit.call(build_conn(), opts)

      # Old entries should be cleaned
      count = :ets.select_count(@table, [{{ip, :"$1"}, [], [true]}])
      assert count == 0
    end
  end

  # Helper to build a basic conn
  defp build_conn do
    conn(:get, "/")
  end
end
