defmodule Custyard.Lettermint.HttpClientInboundDomainTest do
  # async: false - swaps the Lettermint API config for a local server.
  use ExUnit.Case, async: false

  alias Custyard.Lettermint.HttpClient

  defmodule RoutesPlug do
    @moduledoc false
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      {:ok, body, conn} = read_body(conn)
      test_pid = :persistent_term.get({__MODULE__, :test_pid})
      send(test_pid, {:request, conn.method, conn.request_path, body})
      {status, response} = :persistent_term.get({__MODULE__, :respond}).(conn.method)

      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, response)
    end
  end

  setup do
    pid = start_supervised!({Bandit, plug: RoutesPlug, scheme: :http, ip: :loopback, port: 0})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    :persistent_term.put({RoutesPlug, :test_pid}, self())
    original = Application.get_env(:custyard, :lettermint)

    Application.put_env(:custyard, :lettermint,
      client: HttpClient,
      api_url: "http://127.0.0.1:#{port}",
      team_token: "test-api-key"
    )

    on_exit(fn ->
      Application.put_env(:custyard, :lettermint, original)
      :persistent_term.erase({RoutesPlug, :test_pid})
      :persistent_term.erase({RoutesPlug, :respond})
    end)

    :ok
  end

  defp respond_with(fun), do: :persistent_term.put({RoutesPlug, :respond}, fun)

  test "set_inbound_domain/2 PUTs inbound_settings and unwraps the route" do
    route = %{"id" => "rt_1", "inbound_domain" => "help.acme.com"}
    respond_with(fn "PUT" -> {200, Jason.encode!(%{"data" => route, "message" => "Updated"})} end)

    assert {:ok, ^route} = HttpClient.set_inbound_domain("rt_1", "help.acme.com")
    assert_receive {:request, "PUT", "/routes/rt_1", body}
    assert Jason.decode!(body) == %{"inbound_settings" => %{"inbound_domain" => "help.acme.com"}}
  end

  test "set_inbound_domain/2 returns the API error on 422" do
    respond_with(fn "PUT" -> {422, ~s({"message":"The inbound domain is invalid."})} end)

    assert {:error, {:api_error, 422, _}} = HttpClient.set_inbound_domain("rt_1", "bad")
  end

  test "verify_inbound_domain/1 POSTs to verify-inbound-domain and unwraps data" do
    result = %{
      "verified" => false,
      "message" => "MX record not found",
      "expected_mx_records" => ["10 lettermint.mx"],
      "found_mx_records" => ["10 mail.protonmail.ch"]
    }

    respond_with(fn "POST" -> {200, Jason.encode!(%{"data" => result})} end)

    assert {:ok, ^result} = HttpClient.verify_inbound_domain("rt_1")
    assert_receive {:request, "POST", "/routes/rt_1/verify-inbound-domain", ""}
  end

  test "decode_verification/1 accepts the bare object and rejects other shapes" do
    assert {:ok, %{"verified" => true}} = HttpClient.decode_verification(~s({"verified":true}))
    assert {:error, {:unexpected_response, _}} = HttpClient.decode_verification(~s({"data":{}}))
    assert {:error, {:decode_failed, _, _}} = HttpClient.decode_verification("nope")
  end
end
