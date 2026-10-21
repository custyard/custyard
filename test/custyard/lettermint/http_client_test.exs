defmodule Custyard.Lettermint.HttpClientTest do
  use ExUnit.Case, async: true

  alias Custyard.Lettermint.HttpClient

  @route %{
    "id" => "rt_123",
    "slug" => "acme-general",
    "inbound_route_domain" => "ab12cd34ef.lettermint.app",
    "inbound_address" => "0123456789abcdef0123456789abcdef@inbound.lettermint.co",
    "inbound_domain" => nil,
    "inbound_domain_verified_at" => nil
  }

  test "delivery retrieval exposes only valid retained payloads and fixed errors" do
    payload = %{"event" => "message.inbound", "id" => "delivery"}

    assert {:ok, %{"payload" => ^payload}} =
             HttpClient.decode_delivery(Jason.encode!(%{"payload" => payload}))

    assert {:ok, %{"payload" => ^payload}} =
             HttpClient.decode_delivery(Jason.encode!(%{"data" => %{"payload" => payload}}))

    assert {:error, :delivery_content_unavailable} = HttpClient.decode_delivery("secret-url")
    assert {:error, :delivery_content_unavailable} = HttpClient.decode_delivery("{}")
  end

  describe "normalize_route_response/1" do
    test "unwraps the data envelope returned by POST /projects/:id/routes" do
      assert HttpClient.normalize_route_response(%{"data" => @route, "message" => "Created"}) ==
               @route
    end

    test "passes through the bare route returned by GET /routes/:id" do
      assert HttpClient.normalize_route_response(@route) == @route
    end

    test "leaves missing domain keys absent for callers to default" do
      minimal = %{"id" => "rt_old"}

      assert HttpClient.normalize_route_response(%{"data" => minimal}) == minimal
      assert HttpClient.normalize_route_response(minimal) == minimal
      refute Map.has_key?(HttpClient.normalize_route_response(minimal), "inbound_route_domain")
    end

    test "does not unwrap a route that merely has a non-map data field" do
      route = Map.put(@route, "data", "opaque")
      assert HttpClient.normalize_route_response(route) == route
    end
  end
end
