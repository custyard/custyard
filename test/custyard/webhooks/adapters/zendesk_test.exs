defmodule Custyard.Webhooks.Adapters.ZendeskTest do
  use ExUnit.Case, async: true

  alias Custyard.Webhooks.Adapters.Zendesk

  describe "source_name/0" do
    test "returns :zendesk" do
      assert Zendesk.source_name() == :zendesk
    end
  end

  describe "verify_signature/3" do
    test "requires the timestamp-bearing verifier" do
      assert {:error, "Zendesk requires verify_request/4 with a timestamp"} =
               Zendesk.verify_signature("payload", "bad", "secret")
    end
  end

  describe "verify_request/4" do
    test "rejects a signature without timestamp" do
      payload = ~s({"ticket":{"id":123}})
      secret = "zendesk-secret"
      signature = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode64()

      assert {:error, "missing timestamp"} =
               Zendesk.verify_request(payload, nil, signature, secret)
    end

    test "returns :ok for valid signature with the provider's ISO 8601 timestamp" do
      payload = ~s({"ticket":{"id":123}})
      secret = "zendesk-secret"
      timestamp = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      signature = :crypto.mac(:hmac, :sha256, secret, timestamp <> payload) |> Base.encode64()

      assert :ok = Zendesk.verify_request(payload, timestamp, signature, secret)
    end

    test "returns error for stale timestamp" do
      payload = ~s({"ticket":{"id":123}})
      secret = "zendesk-secret"
      # Timestamp from 10 minutes ago (beyond 5 minute skew)
      stale_timestamp =
        DateTime.utc_now()
        |> DateTime.add(-600, :second)
        |> DateTime.truncate(:second)
        |> DateTime.to_iso8601()

      signature =
        :crypto.mac(:hmac, :sha256, secret, stale_timestamp <> payload) |> Base.encode64()

      assert {:error, "stale timestamp" <> _} =
               Zendesk.verify_request(payload, stale_timestamp, signature, secret)
    end

    test "returns error for invalid timestamp format" do
      payload = ~s({"ticket":{"id":123}})
      secret = "zendesk-secret"
      signature = :crypto.mac(:hmac, :sha256, secret, payload) |> Base.encode64()

      assert {:error, "invalid timestamp format"} =
               Zendesk.verify_request(payload, "not-a-number", signature, secret)
    end

    test "returns signature error for valid timestamp" do
      timestamp = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      assert {:error, "invalid signature"} =
               Zendesk.verify_request("payload", timestamp, "bad", "secret")
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
