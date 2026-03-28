defmodule CustyardWeb.Plugs.CacheRawBodyTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias CustyardWeb.Plugs.CacheRawBody

  describe "read_body/2" do
    test "reads body and caches in conn.private[:raw_body]" do
      body = ~s({"event": "test"})
      conn = conn(:post, "/webhook", body)

      {:ok, read_body, conn} = CacheRawBody.read_body(conn, [])

      assert read_body == body
      assert conn.private[:raw_body] == body
    end

    test "handles empty body" do
      conn = conn(:post, "/webhook", "")

      {:ok, read_body, conn} = CacheRawBody.read_body(conn, [])

      assert read_body == ""
      assert conn.private[:raw_body] == ""
    end

    test "returns error for body exceeding default limit" do
      # Default limit is 1MB (1_000_000 bytes)
      large_body = String.duplicate("a", 1_000_001)
      conn = conn(:post, "/webhook", large_body)

      # Plug converts {:more, ...} from Plug.Conn.read_body to {:error, :body_too_large, conn}
      assert {:error, :body_too_large, _conn} = CacheRawBody.read_body(conn, [])
    end

    test "respects custom length option" do
      # Set a small custom limit
      body = "short body"
      conn = conn(:post, "/webhook", body)

      {:ok, read_body, conn} = CacheRawBody.read_body(conn, length: 100)

      assert read_body == body
      assert conn.private[:raw_body] == body
    end

    test "preserves raw body bytes for signature verification" do
      # JSON with specific formatting that must be preserved
      body = ~s({"key":  "value",\n"num": 123})
      conn = conn(:post, "/webhook", body)

      {:ok, read_body, conn} = CacheRawBody.read_body(conn, [])

      # Exact bytes preserved including whitespace
      assert read_body == body
      assert conn.private[:raw_body] == body
    end

    test "handles binary/non-UTF8 content" do
      # Simulate binary content that might come from some webhooks
      body = <<0x89, 0x50, 0x4E, 0x47, "test">>
      conn = conn(:post, "/webhook", body)

      {:ok, read_body, conn} = CacheRawBody.read_body(conn, [])

      assert read_body == body
      assert conn.private[:raw_body] == body
    end

    test "uses application config for max body size" do
      # Save original config
      original = Application.get_env(:custyard, :webhook_max_body_size)

      try do
        # Set a very small limit via config
        Application.put_env(:custyard, :webhook_max_body_size, 10)

        body = String.duplicate("a", 11)
        conn = conn(:post, "/webhook", body)

        # Should return error because body exceeds 10 bytes
        assert {:error, :body_too_large, _conn} = CacheRawBody.read_body(conn, [])
      after
        # Restore original config
        if original do
          Application.put_env(:custyard, :webhook_max_body_size, original)
        else
          Application.delete_env(:custyard, :webhook_max_body_size)
        end
      end
    end

    test "body within limit is read successfully" do
      # Body at exactly the limit should work
      Application.put_env(:custyard, :webhook_max_body_size, 100)

      try do
        body = String.duplicate("x", 100)
        conn = conn(:post, "/webhook", body)

        {:ok, read_body, conn} = CacheRawBody.read_body(conn, [])

        assert read_body == body
        assert conn.private[:raw_body] == body
      after
        Application.delete_env(:custyard, :webhook_max_body_size)
      end
    end
  end
end
