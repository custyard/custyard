defmodule Custyard.Webhooks.NormalizerTest do
  use ExUnit.Case, async: true

  alias Custyard.Webhooks.Normalizer

  describe "normalize/2" do
    test "normalizes using lettermint adapter" do
      params = %{"from" => "alice@example.com", "subject" => "Test", "text" => "Body"}

      assert {:ok, normalized} = Normalizer.normalize(:lettermint, params)
      assert normalized.source == :lettermint
      assert normalized.from == "alice@example.com"
    end

    test "normalizes using zendesk adapter" do
      params = %{
        "ticket" => %{
          "id" => 1,
          "subject" => "Help",
          "description" => "I need help",
          "requester" => %{"email" => "bob@example.com"}
        }
      }

      assert {:ok, normalized} = Normalizer.normalize(:zendesk, params)
      assert normalized.source == :zendesk
    end

    test "returns error for unknown source" do
      assert {:error, _} = Normalizer.normalize(:unknown, %{})
    end
  end

  describe "normalize_legacy/1" do
    test "normalizes using lettermint format" do
      params = %{"from" => "alice@example.com", "text" => "Body"}

      assert {:ok, normalized} = Normalizer.normalize_legacy(params)
      assert normalized.source == :lettermint
    end
  end
end
