defmodule Custyard.Lettermint.MockClientTest do
  # async: false — stages domains in the application environment.
  use ExUnit.Case, async: false

  alias Custyard.Lettermint.{FailingMockClient, MockClient}

  setup do
    on_exit(fn -> Application.delete_env(:custyard, :lettermint_mock_domains) end)
  end

  describe "MockClient.list_domains/0" do
    test "is empty by default" do
      assert MockClient.list_domains() == {:ok, []}
    end

    test "returns the staged domains" do
      domains = [%{"id" => "d1", "domain" => "acme.example.com", "status" => "verified"}]
      Application.put_env(:custyard, :lettermint_mock_domains, domains)

      assert MockClient.list_domains() == {:ok, domains}
    end
  end

  describe "FailingMockClient.list_domains/0" do
    test "fails with a service error by default" do
      assert FailingMockClient.list_domains() ==
               {:error, {:api_error, 503, "Service Unavailable"}}
    end

    test "returns the configured error" do
      Process.put({:failing_mock_client, :list_domains}, {:error, {:request_failed, :timeout}})
      assert FailingMockClient.list_domains() == {:error, {:request_failed, :timeout}}
    end
  end
end
