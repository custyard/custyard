defmodule Custyard.Webhooks.Adapters.IntercomTest do
  use ExUnit.Case, async: true

  alias Custyard.Webhooks.Adapters.Intercom

  describe "source_name/0" do
    test "returns :intercom" do
      assert Intercom.source_name() == :intercom
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
    end
  end
end
