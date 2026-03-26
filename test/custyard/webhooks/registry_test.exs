defmodule Custyard.Webhooks.RegistryTest do
  use ExUnit.Case, async: true

  alias Custyard.Webhooks.Registry

  describe "get_adapter/1" do
    test "returns adapter for known atom source" do
      assert Registry.get_adapter(:lettermint) == Custyard.Webhooks.Adapters.Lettermint
      assert Registry.get_adapter(:zendesk) == Custyard.Webhooks.Adapters.Zendesk
      assert Registry.get_adapter(:intercom) == Custyard.Webhooks.Adapters.Intercom
      assert Registry.get_adapter(:slack) == Custyard.Webhooks.Adapters.Slack
    end

    test "returns adapter for known string source" do
      assert Registry.get_adapter("lettermint") == Custyard.Webhooks.Adapters.Lettermint
    end

    test "returns nil for unknown source" do
      assert Registry.get_adapter(:unknown) == nil
      assert Registry.get_adapter("nonexistent") == nil
    end
  end

  describe "known_source?/1" do
    test "returns true for known sources" do
      assert Registry.known_source?(:lettermint)
      assert Registry.known_source?(:zendesk)
      assert Registry.known_source?("intercom")
    end

    test "returns false for unknown sources" do
      refute Registry.known_source?(:unknown)
      refute Registry.known_source?("nonexistent")
    end
  end

  describe "sources/0" do
    test "returns all registered sources" do
      sources = Registry.sources()
      assert :lettermint in sources
      assert :zendesk in sources
      assert :intercom in sources
      assert :slack in sources
    end
  end
end
