defmodule CustyardWeb.ClientIPTest do
  # Mutates the :trust_proxy_headers app env — must not run concurrently
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias CustyardWeb.ClientIP

  describe "from_conn/1 with trust_proxy_headers disabled (default)" do
    setup do
      Application.delete_env(:custyard, :trust_proxy_headers)
      :ok
    end

    test "uses the peer address when no headers are present" do
      assert ClientIP.from_conn(conn(:get, "/")) == "127.0.0.1"
    end

    test "ignores x-forwarded-for from untrusted clients" do
      conn =
        conn(:get, "/")
        |> put_req_header("x-forwarded-for", "198.51.100.10")

      assert ClientIP.from_conn(conn) == "127.0.0.1"
    end

    test "ignores fly-client-ip from untrusted clients" do
      conn =
        conn(:get, "/")
        |> put_req_header("fly-client-ip", "203.0.113.42")

      assert ClientIP.from_conn(conn) == "127.0.0.1"
    end
  end

  describe "from_conn/1 with trust_proxy_headers enabled" do
    setup do
      Application.put_env(:custyard, :trust_proxy_headers, true)

      on_exit(fn ->
        Application.delete_env(:custyard, :trust_proxy_headers)
      end)

      :ok
    end

    test "honors fly-client-ip, trimming whitespace" do
      conn =
        conn(:get, "/")
        |> put_req_header("fly-client-ip", "  203.0.113.42  ")

      assert ClientIP.from_conn(conn) == "203.0.113.42"
    end

    test "honors the rightmost x-forwarded-for entry (proxy-appended)" do
      conn =
        conn(:get, "/")
        |> put_req_header("x-forwarded-for", "10.0.0.1, 10.0.0.2 , 198.51.100.10 ")

      assert ClientIP.from_conn(conn) == "198.51.100.10"
    end

    test "a client-prepended x-forwarded-for entry cannot displace the real client" do
      # The edge proxy APPENDS the peer it saw; anything the client sent
      # stays on the left. A spoofed valid IP must not become the key.
      conn =
        conn(:get, "/")
        |> put_req_header("x-forwarded-for", "6.6.6.6, 198.51.100.10")

      assert ClientIP.from_conn(conn) == "198.51.100.10"
    end

    test "prefers fly-client-ip over x-forwarded-for" do
      conn =
        conn(:get, "/")
        |> put_req_header("fly-client-ip", "203.0.113.100")
        |> put_req_header("x-forwarded-for", "198.51.100.200")

      assert ClientIP.from_conn(conn) == "203.0.113.100"
    end

    test "accepts IPv6 addresses" do
      conn =
        conn(:get, "/")
        |> put_req_header("x-forwarded-for", "10.0.0.1, 2001:db8::1")

      assert ClientIP.from_conn(conn) == "2001:db8::1"
    end

    test "falls back to the peer address when no headers are present" do
      assert ClientIP.from_conn(conn(:get, "/")) == "127.0.0.1"
    end

    test "malformed fly-client-ip falls through to a valid x-forwarded-for" do
      conn =
        conn(:get, "/")
        |> put_req_header("fly-client-ip", "not-an-ip")
        |> put_req_header("x-forwarded-for", "198.51.100.10")

      assert ClientIP.from_conn(conn) == "198.51.100.10"
    end

    test "malformed x-forwarded-for falls back to the peer address" do
      conn =
        conn(:get, "/")
        |> put_req_header("x-forwarded-for", "garbage;;value")

      assert ClientIP.from_conn(conn) == "127.0.0.1"
    end

    test "empty header values fall back to the peer address" do
      conn =
        conn(:get, "/")
        |> put_req_header("fly-client-ip", "")
        |> put_req_header("x-forwarded-for", "10.0.0.1, ")

      assert ClientIP.from_conn(conn) == "127.0.0.1"
    end
  end

  describe "from_peer_data/2 (LiveView connect info)" do
    @peer_data %{address: {203, 0, 113, 9}, port: 51_234, ssl_cert: nil}

    test "uses the peer address when proxy headers are untrusted" do
      Application.delete_env(:custyard, :trust_proxy_headers)

      x_headers = [{"x-forwarded-for", "198.51.100.10"}]

      assert ClientIP.from_peer_data(@peer_data, x_headers) == "203.0.113.9"
    end

    test "honors the rightmost x-forwarded-for entry when trusted" do
      Application.put_env(:custyard, :trust_proxy_headers, true)
      on_exit(fn -> Application.delete_env(:custyard, :trust_proxy_headers) end)

      x_headers = [
        {"x-request-id", "abc123"},
        {"x-forwarded-for", "10.0.0.1, 198.51.100.10"}
      ]

      assert ClientIP.from_peer_data(@peer_data, x_headers) == "198.51.100.10"
    end

    test "a client-prepended x-forwarded-for entry resolves to the real client when trusted" do
      # A websocket client controls its own XFF header; the edge proxy
      # appends the real peer at the END. The spoofed leftmost valid IP
      # must not win, or every IP-keyed socket bucket is mintable.
      Application.put_env(:custyard, :trust_proxy_headers, true)
      on_exit(fn -> Application.delete_env(:custyard, :trust_proxy_headers) end)

      x_headers = [{"x-forwarded-for", "6.6.6.6, 198.51.100.10"}]

      assert ClientIP.from_peer_data(@peer_data, x_headers) == "198.51.100.10"
    end

    test "the rightmost entry across multiple x-forwarded-for headers wins when trusted" do
      Application.put_env(:custyard, :trust_proxy_headers, true)
      on_exit(fn -> Application.delete_env(:custyard, :trust_proxy_headers) end)

      x_headers = [
        {"x-forwarded-for", "6.6.6.6"},
        {"x-forwarded-for", "198.51.100.10"}
      ]

      assert ClientIP.from_peer_data(@peer_data, x_headers) == "198.51.100.10"
    end

    test "malformed x-forwarded-for falls back to the peer address when trusted" do
      Application.put_env(:custyard, :trust_proxy_headers, true)
      on_exit(fn -> Application.delete_env(:custyard, :trust_proxy_headers) end)

      x_headers = [{"x-forwarded-for", "not-an-ip"}]

      assert ClientIP.from_peer_data(@peer_data, x_headers) == "203.0.113.9"
    end

    test "returns nil when neither source is available" do
      Application.delete_env(:custyard, :trust_proxy_headers)

      assert ClientIP.from_peer_data(nil, nil) == nil
      assert ClientIP.from_peer_data(nil, []) == nil
    end
  end
end
