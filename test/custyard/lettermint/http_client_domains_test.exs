defmodule Custyard.Lettermint.HttpClientDomainsTest do
  # async: false — swaps the Lettermint API config for a local server.
  use ExUnit.Case, async: false

  alias Custyard.Lettermint.HttpClient

  defmodule DomainsPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      conn = fetch_query_params(conn)
      test_pid = :persistent_term.get({__MODULE__, :test_pid})
      send(test_pid, {:request, conn.request_path, conn.query_params, conn.req_headers})

      {status, body} =
        :persistent_term.get({__MODULE__, :respond}).(
          get_in(conn.query_params, ["page", "cursor"])
        )

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, body)
    end
  end

  setup do
    pid = start_supervised!({Bandit, plug: DomainsPlug, scheme: :http, ip: :loopback, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)

    :persistent_term.put({DomainsPlug, :test_pid}, self())

    original = Application.get_env(:custyard, :lettermint)

    Application.put_env(:custyard, :lettermint,
      client: HttpClient,
      api_url: "http://127.0.0.1:#{port}/",
      api_key: "test-api-key"
    )

    on_exit(fn ->
      Application.put_env(:custyard, :lettermint, original)
      :persistent_term.erase({DomainsPlug, :test_pid})
      :persistent_term.erase({DomainsPlug, :respond})
    end)

    :ok
  end

  defp respond_with(fun), do: :persistent_term.put({DomainsPlug, :respond}, fun)

  defp domain(id, status \\ "verified"),
    do: %{"id" => id, "domain" => "#{id}.example.com", "status" => status}

  describe "list_domains/0" do
    test "requests GET /domains with the bearer token and unwraps data" do
      respond_with(fn _cursor -> {200, Jason.encode!(%{"data" => [domain("d1")]})} end)

      assert {:ok, [%{"id" => "d1", "status" => "verified"}]} = HttpClient.list_domains()

      assert_receive {:request, "/domains", %{"page" => %{"size" => "100"} = page}, headers}
      refute Map.has_key?(page, "cursor")
      assert {"authorization", "Bearer test-api-key"} in headers
    end

    test "follows next_cursor and concatenates pages in order" do
      respond_with(fn
        nil ->
          {200, Jason.encode!(%{"data" => [domain("d1")], "next_cursor" => "c2"})}

        "c2" ->
          {200, Jason.encode!(%{"data" => [domain("d2")], "meta" => %{"next_cursor" => "c3"}})}

        "c3" ->
          {200, Jason.encode!(%{"data" => [domain("d3")], "next_cursor" => nil})}
      end)

      assert {:ok, domains} = HttpClient.list_domains()
      assert Enum.map(domains, & &1["id"]) == ["d1", "d2", "d3"]

      assert_receive {:request, "/domains", %{"page" => %{"size" => "100"} = first}, _}
      refute Map.has_key?(first, "cursor")
      assert_receive {:request, "/domains", %{"page" => %{"cursor" => "c2", "size" => "100"}}, _}
      assert_receive {:request, "/domains", %{"page" => %{"cursor" => "c3", "size" => "100"}}, _}
      refute_receive {:request, _, _, _}
    end

    test "uses the tenant Team credential and selected project filter" do
      respond_with(fn _ -> {200, Jason.encode!(%{"data" => [domain("allowed")]})} end)
      config = Application.get_env(:custyard, :lettermint)

      assert {:ok, [_]} =
               HttpClient.list_domains(
                 api_url: config[:api_url],
                 team_token: "tenant-team-token",
                 project_id: "project-1"
               )

      assert_receive {:request, "/domains", %{"filter" => %{"project" => "project-1"}}, headers}
      assert {"authorization", "Bearer tenant-team-token"} in headers
      refute Enum.any?(headers, fn {name, _} -> name == "x-lettermint-token" end)
    end

    test "stops after five pages even when a cursor keeps coming back" do
      respond_with(fn cursor ->
        {200, Jason.encode!(%{"data" => [domain("d-#{cursor}")], "next_cursor" => "again"})}
      end)

      assert {:ok, domains} = HttpClient.list_domains()
      assert length(domains) == 5

      for _ <- 1..5, do: assert_receive({:request, "/domains", _, _})
      refute_receive {:request, _, _, _}
    end

    test "returns the API error on a non-2xx status" do
      respond_with(fn _ -> {401, ~s({"message":"Unauthenticated"})} end)

      assert {:error, {:api_error, 401, body}} = HttpClient.list_domains()
      assert body =~ "Unauthenticated"
    end

    test "returns an unexpected_response error when data is not a list" do
      respond_with(fn _ -> {200, ~s({"data":{"id":"d1"}})} end)

      assert {:error, {:unexpected_response, %{"data" => %{"id" => "d1"}}}} =
               HttpClient.list_domains()
    end

    test "returns a request_failed error when the server is unreachable" do
      Application.put_env(:custyard, :lettermint,
        client: HttpClient,
        api_url: "http://127.0.0.1:1/",
        api_key: "test-api-key"
      )

      assert {:error, {:request_failed, _reason}} = HttpClient.list_domains()
    end
  end

  describe "decode_domains_page/1" do
    test "returns the domains and the cursor from either location" do
      assert HttpClient.decode_domains_page(~s({"data":[],"next_cursor":"abc"})) ==
               {:ok, {[], "abc"}}

      assert HttpClient.decode_domains_page(~s({"data":[],"meta":{"next_cursor":"xyz"}})) ==
               {:ok, {[], "xyz"}}

      assert HttpClient.decode_domains_page(~s({"data":[]})) == {:ok, {[], nil}}
    end

    test "reports malformed bodies" do
      assert {:error, {:decode_failed, _, "not json"}} =
               HttpClient.decode_domains_page("not json")

      assert {:error, {:unexpected_response, []}} = HttpClient.decode_domains_page("[]")
    end
  end
end
