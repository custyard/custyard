defmodule Custyard.Webhooks.Adapters.LettermintTest do
  use ExUnit.Case, async: true

  alias Custyard.Webhooks.Adapters.Lettermint

  describe "source_name/0" do
    test "returns :lettermint" do
      assert Lettermint.source_name() == :lettermint
    end
  end

  describe "verify_signature/3" do
    test "returns :ok for valid HMAC-SHA256 signature" do
      payload = ~s({"from":"alice@example.com"})
      secret = "test-secret-key"
      signature = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)

      assert :ok = Lettermint.verify_signature(payload, signature, secret)
    end

    test "returns :ok with sha256= prefix" do
      payload = ~s({"from":"alice@example.com"})
      secret = "test-secret-key"
      hmac = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode16(case: :lower)
      signature = "sha256=#{hmac}"

      assert :ok = Lettermint.verify_signature(payload, signature, secret)
    end

    test "returns error for invalid signature" do
      assert {:error, "invalid signature"} =
               Lettermint.verify_signature("payload", "bad-sig", "secret")
    end

    test "returns error for missing signature" do
      assert {:error, "missing signature header"} =
               Lettermint.verify_signature("payload", nil, "secret")
    end

    test "returns error for no secret configured" do
      assert {:error, "no secret configured"} = Lettermint.verify_signature("payload", "sig", nil)
    end
  end

  describe "normalize/1" do
    test "normalizes standard email payload" do
      params = %{
        "from" => "alice@example.com",
        "to" => "support@custyard.test",
        "subject" => "Need help",
        "text" => "Hello there",
        "headers" => %{
          "message-id" => "abc123@example.com",
          "in-reply-to" => "prev@example.com"
        }
      }

      assert {:ok, normalized} = Lettermint.normalize(params)
      assert normalized.from == "alice@example.com"
      assert normalized.to == "support@custyard.test"
      assert normalized.subject == "Need help"
      assert normalized.body == "Hello there"
      assert normalized.message_id == "abc123@example.com"
      assert normalized.in_reply_to == "prev@example.com"
      assert normalized.source == :lettermint
    end

    test "falls back to sender/recipient fields" do
      params = %{"sender" => "bob@example.com", "recipient" => "inbox@test.com"}

      assert {:ok, normalized} = Lettermint.normalize(params)
      assert normalized.from == "bob@example.com"
      assert normalized.to == "inbox@test.com"
    end

    test "defaults subject to (no subject)" do
      params = %{"from" => "alice@example.com", "text" => "body"}

      assert {:ok, normalized} = Lettermint.normalize(params)
      assert normalized.subject == "(no subject)"
    end

    test "strips HTML when no text body" do
      params = %{
        "from" => "alice@example.com",
        "html" => "<p>Hello <strong>world</strong></p>"
      }

      assert {:ok, normalized} = Lettermint.normalize(params)
      assert normalized.body =~ "Hello"
      assert normalized.body =~ "world"
      refute normalized.body =~ "<"
    end

    test "handles case-insensitive headers" do
      params = %{
        "from" => "alice@example.com",
        "headers" => %{"Message-Id" => "abc@example.com"}
      }

      assert {:ok, normalized} = Lettermint.normalize(params)
      assert normalized.message_id == "abc@example.com"
    end
  end
end
