defmodule Custyard.LettermintConfigTest do
  use ExUnit.Case, async: true

  alias Custyard.Lettermint.Client
  alias Custyard.Lettermint.MockClient
  alias Custyard.Lettermint.HttpClient

  describe "test environment defaults (from config.exs)" do
    test "lettermint client is MockClient when env vars are absent" do
      lettermint_config = Application.get_env(:custyard, :lettermint)
      assert Keyword.fetch!(lettermint_config, :client) == MockClient
    end

    test "lettermint_configured is false when env vars are absent" do
      refute Application.get_env(:custyard, :lettermint_configured)
    end

    test "Client.client/0 returns MockClient" do
      assert Client.client() == MockClient
    end
  end

  describe "MockClient is callable" do
    test "create_route/1 returns an ok tuple with an id" do
      assert {:ok, %{"id" => id}} = MockClient.create_route(%{})
      assert is_binary(id)
      assert String.starts_with?(id, "lm_route_")
    end

    test "delete_route/1 returns :ok" do
      assert :ok = MockClient.delete_route("lm_route_123")
    end
  end

  describe "HttpClient module" do
    test "HttpClient exists and implements the Client behaviour" do
      assert {:module, HttpClient} = Code.ensure_loaded(HttpClient)
      assert function_exported?(HttpClient, :create_route, 1)
      assert function_exported?(HttpClient, :delete_route, 1)
    end
  end
end
