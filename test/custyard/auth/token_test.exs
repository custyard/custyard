defmodule Custyard.Auth.TokenTest do
  use ExUnit.Case, async: true

  alias Custyard.Auth.Token

  describe "generate/0" do
    test "returns a 256-bit url-safe token and its hash" do
      {token, hash} = Token.generate()

      # 32 random bytes url-encoded without padding = 43 chars
      assert String.length(token) == 43
      assert {:ok, raw} = Base.url_decode64(token, padding: false)
      assert byte_size(raw) == 32

      assert hash == Token.hash(token)
      refute token == hash
    end

    test "generates unique tokens" do
      tokens = for _ <- 1..10, do: Token.generate() |> elem(0)
      assert length(Enum.uniq(tokens)) == 10
    end
  end

  describe "hash/1" do
    test "is deterministic" do
      assert Token.hash("some-token") == Token.hash("some-token")
    end

    test "is url-safe base64 of the SHA-256 digest" do
      expected = Base.url_encode64(:crypto.hash(:sha256, "some-token"), padding: false)
      assert Token.hash("some-token") == expected
    end

    test "differs across tokens" do
      refute Token.hash("token-a") == Token.hash("token-b")
    end
  end
end
