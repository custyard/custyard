defmodule Custyard.Webhooks.SignatureTest do
  use ExUnit.Case, async: true

  alias Custyard.Webhooks.Signature

  describe "verify/4" do
    test "delegates to lettermint adapter" do
      payload = "test-payload"
      secret = "test-secret"
      sig = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)

      assert :ok = Signature.verify(:lettermint, payload, sig, secret)
    end

    test "returns error for unknown source" do
      assert {:error, "unknown source: " <> _} = Signature.verify(:unknown, "p", "s", "k")
    end
  end

  describe "verify_api_key/2" do
    test "returns :ok for matching key" do
      assert :ok = Signature.verify_api_key("my-key-123", "my-key-123")
    end

    test "returns error for mismatched key" do
      assert {:error, "invalid API key"} = Signature.verify_api_key("wrong", "correct")
    end

    test "returns error for nil key" do
      assert {:error, "missing API key"} = Signature.verify_api_key(nil, "expected")
    end
  end
end
