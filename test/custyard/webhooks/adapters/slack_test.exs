defmodule Custyard.Webhooks.Adapters.SlackTest do
  use ExUnit.Case, async: true

  alias Custyard.Webhooks.Adapters.Slack

  describe "source_name/0" do
    test "returns :slack" do
      assert Slack.source_name() == :slack
    end
  end

  describe "normalize/1" do
    test "normalizes message event" do
      params = %{
        "team_id" => "T12345",
        "event" => %{
          "type" => "message",
          "user" => "U12345",
          "channel" => "C67890",
          "text" => "Hey, I need some help with my deployment",
          "ts" => "1234567890.123456",
          "thread_ts" => nil
        }
      }

      assert {:ok, normalized} = Slack.normalize(params)
      assert normalized.from == "U12345"
      assert normalized.to == "C67890"
      assert normalized.body == "Hey, I need some help with my deployment"
      assert normalized.source == :slack
      assert normalized.metadata.channel == "C67890"
    end

    test "normalizes threaded reply" do
      params = %{
        "event" => %{
          "type" => "message",
          "user" => "U12345",
          "channel" => "C67890",
          "text" => "Thanks for the update",
          "ts" => "1234567891.123456",
          "thread_ts" => "1234567890.123456"
        }
      }

      assert {:ok, normalized} = Slack.normalize(params)
      assert normalized.in_reply_to == "slack-C67890-1234567890.123456@slack.webhook"
    end

    test "handles URL verification challenge with bypass" do
      params = %{
        "type" => "url_verification",
        "challenge" => "abc123xyz"
      }

      assert {:bypass, result} = Slack.normalize(params)
      assert result.type == "url_verification"
      assert result.challenge == "abc123xyz"
      assert result.source == :slack
    end

    test "truncates long text for subject" do
      long_text = String.duplicate("a", 100)

      params = %{
        "event" => %{
          "text" => long_text,
          "user" => "U1",
          "channel" => "C1"
        }
      }

      assert {:ok, normalized} = Slack.normalize(params)
      assert String.length(normalized.subject) == 80
      assert String.ends_with?(normalized.subject, "...")
    end
  end

  describe "verify_signature/3" do
    test "returns :ok for valid signature" do
      payload = "test-payload"
      secret = "test-secret"

      hmac =
        :crypto.mac(:hmac, :sha256, secret, payload)
        |> Base.encode16(case: :lower)

      signature = "v0=" <> hmac

      assert :ok = Slack.verify_signature(payload, signature, secret)
    end

    test "returns error for invalid signature" do
      assert {:error, "invalid signature"} =
               Slack.verify_signature("payload", "v0=bad", "secret")
    end

    test "returns error for missing signature" do
      assert {:error, "missing signature header"} =
               Slack.verify_signature("payload", nil, "secret")
    end

    test "returns error for no secret" do
      assert {:error, "no secret configured"} =
               Slack.verify_signature("payload", "sig", nil)
    end
  end

  describe "verify_request/4" do
    test "verifies with proper timestamp-based signing" do
      secret = "test-secret"
      body = ~s({"event":{"type":"message"}})
      timestamp = to_string(System.system_time(:second))

      base_string = "v0:" <> timestamp <> ":" <> body

      hmac =
        :crypto.mac(:hmac, :sha256, secret, base_string)
        |> Base.encode16(case: :lower)

      signature = "v0=" <> hmac

      assert :ok = Slack.verify_request(body, timestamp, signature, secret)
    end

    test "rejects stale timestamp" do
      secret = "test-secret"
      body = "payload"
      # 10 minutes ago — beyond the 5-minute window
      old_timestamp = to_string(System.system_time(:second) - 600)

      hmac =
        :crypto.mac(:hmac, :sha256, secret, "v0:#{old_timestamp}:#{body}")
        |> Base.encode16(case: :lower)

      signature = "v0=" <> hmac

      assert {:error, "stale timestamp"} =
               Slack.verify_request(body, old_timestamp, signature, secret)
    end
  end
end
