defmodule Custyard.Webhooks.Adapters.ZendeskTest do
  use ExUnit.Case, async: true

  alias Custyard.Webhooks.Adapters.Zendesk

  describe "source_name/0" do
    test "returns :zendesk" do
      assert Zendesk.source_name() == :zendesk
    end
  end

  describe "verify_signature/3" do
    test "returns :ok for valid signature" do
      payload = ~s({"ticket":{"id":123}})
      secret = "zendesk-secret"
      signature = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode64()

      assert :ok = Zendesk.verify_signature(payload, signature, secret)
    end

    test "returns error for invalid signature" do
      assert {:error, "invalid signature"} = Zendesk.verify_signature("payload", "bad", "secret")
    end
  end

  describe "verify_request/4" do
    test "returns :ok for valid signature without timestamp" do
      payload = ~s({"ticket":{"id":123}})
      secret = "zendesk-secret"
      signature = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode64()

      assert :ok = Zendesk.verify_request(payload, nil, signature, secret)
    end

    test "returns :ok for valid signature with valid timestamp" do
      payload = ~s({"ticket":{"id":123}})
      secret = "zendesk-secret"
      signature = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode64()
      timestamp = to_string(System.system_time(:second))

      assert :ok = Zendesk.verify_request(payload, timestamp, signature, secret)
    end

    test "returns error for stale timestamp" do
      payload = ~s({"ticket":{"id":123}})
      secret = "zendesk-secret"
      signature = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode64()
      # Timestamp from 10 minutes ago (beyond 5 minute skew)
      stale_timestamp = to_string(System.system_time(:second) - 600)

      assert {:error, "stale timestamp" <> _} = Zendesk.verify_request(payload, stale_timestamp, signature, secret)
    end

    test "returns error for invalid timestamp format" do
      payload = ~s({"ticket":{"id":123}})
      secret = "zendesk-secret"
      signature = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode64()

      assert {:error, "invalid timestamp format"} = Zendesk.verify_request(payload, "not-a-number", signature, secret)
    end

    test "returns signature error before checking timestamp" do
      assert {:error, "invalid signature"} = Zendesk.verify_request("payload", "123", "bad", "secret")
    end
  end

  describe "normalize/1" do
    test "normalizes ticket creation payload" do
      params = %{
        "ticket" => %{
          "id" => 12_345,
          "subject" => "Cannot access account",
          "description" => "I need help resetting my password",
          "status" => "new",
          "priority" => "high",
          "tags" => ["account", "password"],
          "requester" => %{
            "name" => "Alice Smith",
            "email" => "alice@example.com"
          }
        }
      }

      assert {:ok, normalized} = Zendesk.normalize(params)
      assert normalized.from == "Alice Smith <alice@example.com>"
      assert normalized.subject == "Cannot access account"
      assert normalized.body == "I need help resetting my password"
      assert normalized.message_id == "zendesk-12345@zendesk.webhook"
      assert normalized.source == :zendesk
      assert normalized.metadata.external_id == "12345"
      assert normalized.metadata.external_priority == "high"
    end

    test "handles payload without requester" do
      params = %{
        "ticket" => %{
          "id" => 1,
          "subject" => "Test"
        },
        "current_user_email" => "bob@example.com"
      }

      assert {:ok, normalized} = Zendesk.normalize(params)
      assert normalized.from == "bob@example.com"
    end
  end
end
