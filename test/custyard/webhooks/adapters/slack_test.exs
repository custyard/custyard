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

    test "handles URL verification challenge" do
      params = %{
        "type" => "url_verification",
        "challenge" => "abc123xyz"
      }

      assert {:ok, normalized} = Slack.normalize(params)
      assert normalized.body == "abc123xyz"
      assert normalized.metadata.type == "url_verification"
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
end
