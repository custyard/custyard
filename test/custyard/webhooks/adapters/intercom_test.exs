defmodule Custyard.Webhooks.Adapters.IntercomTest do
  use ExUnit.Case, async: true

  alias Custyard.Webhooks.Adapters.Intercom

  describe "source_name/0" do
    test "returns :intercom" do
      assert Intercom.source_name() == :intercom
    end
  end

  describe "verify_signature/3" do
    test "returns :ok for valid signature" do
      payload = ~s({"data":{"item":{"id":"123"}}})
      secret = "intercom-secret"
      hmac = :crypto.mac(:hmac, :sha, secret, payload) |> Base.encode16(case: :lower)
      signature = "sha1=" <> hmac

      assert :ok = Intercom.verify_signature(payload, signature, secret)
    end

    test "returns error for invalid signature" do
      assert {:error, "invalid signature"} =
               Intercom.verify_signature("payload", "sha1=bad", "secret")
    end
  end

  describe "verify_request/4" do
    test "returns :ok for valid signature without timestamp" do
      payload = ~s({"data":{"item":{"id":"123"}}})
      secret = "intercom-secret"
      hmac = :crypto.mac(:hmac, :sha, secret, payload) |> Base.encode16(case: :lower)
      signature = "sha1=" <> hmac

      assert :ok = Intercom.verify_request(payload, nil, signature, secret)
    end

    test "returns :ok for valid signature with valid timestamp" do
      payload = ~s({"data":{"item":{"id":"123"}}})
      secret = "intercom-secret"
      hmac = :crypto.mac(:hmac, :sha, secret, payload) |> Base.encode16(case: :lower)
      signature = "sha1=" <> hmac
      timestamp = to_string(System.system_time(:second))

      assert :ok = Intercom.verify_request(payload, timestamp, signature, secret)
    end

    test "returns error for stale timestamp" do
      payload = ~s({"data":{"item":{"id":"123"}}})
      secret = "intercom-secret"
      hmac = :crypto.mac(:hmac, :sha, secret, payload) |> Base.encode16(case: :lower)
      signature = "sha1=" <> hmac
      # Timestamp from 10 minutes ago (beyond 5 minute skew)
      stale_timestamp = to_string(System.system_time(:second) - 600)

      assert {:error, "stale timestamp" <> _} =
               Intercom.verify_request(payload, stale_timestamp, signature, secret)
    end

    test "returns signature error before checking timestamp" do
      assert {:error, "invalid signature"} =
               Intercom.verify_request("payload", "123", "sha1=bad", "secret")
    end
  end

  describe "normalize/1" do
    test "normalizes conversation created event" do
      params = %{
        "topic" => "conversation.user.created",
        "data" => %{
          "item" => %{
            "id" => "conv_abc123",
            "source" => %{
              "subject" => "Help with billing",
              "body" => "I have a question about my invoice",
              "author" => %{
                "name" => "Alice",
                "email" => "alice@example.com",
                "type" => "user"
              }
            }
          }
        }
      }

      assert {:ok, normalized} = Intercom.normalize(params)
      assert normalized.from == "Alice <alice@example.com>"
      assert normalized.subject == "Help with billing"
      assert normalized.body == "I have a question about my invoice"
      assert normalized.source == :intercom
      assert normalized.metadata.external_id == "conv_abc123"
      assert normalized.metadata.topic == "conversation.user.created"
      # message_id and in_reply_to match format for threading
      assert normalized.message_id == "intercom-conv_abc123@intercom.webhook"
      assert normalized.in_reply_to == "intercom-conv_abc123@intercom.webhook"
    end

    test "uses part ID when conversation parts are present" do
      params = %{
        "topic" => "conversation.user.replied",
        "data" => %{
          "item" => %{
            "id" => "conv_abc123",
            "source" => %{
              "subject" => "Help with billing",
              "body" => "Original message"
            },
            "conversation_parts" => %{
              "conversation_parts" => [
                %{
                  "id" => "part_789",
                  "body" => "A reply to the conversation",
                  "author" => %{
                    "email" => "alice@example.com",
                    "type" => "user"
                  }
                }
              ]
            }
          }
        }
      }

      assert {:ok, normalized} = Intercom.normalize(params)
      assert normalized.body == "A reply to the conversation"
      # Part messages have unique message_id, but in_reply_to references parent conversation
      assert normalized.message_id == "intercom-conv_abc123-part-part_789@intercom.webhook"
      assert normalized.in_reply_to == "intercom-conv_abc123@intercom.webhook"
    end
  end
end
