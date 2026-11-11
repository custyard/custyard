defmodule CustyardWeb.ProxyTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias CustyardWeb.{Endpoint, Proxy}

  @secret "isolated-test-origin-secret-at-least-32-bytes"
  @bunny [provider: :bunny, secret: @secret, https_required: false]

  test "Bunny authenticates before endpoint static files and Phoenix socket dispatch" do
    original =
      for key <- [:proxy_provider, :bunny_origin_secret],
          do: {key, Application.fetch_env(:custyard, key)}

    Application.put_env(:custyard, :proxy_provider, :bunny)
    Application.put_env(:custyard, :bunny_origin_secret, @secret)

    on_exit(fn ->
      for {key, value} <- original do
        case value do
          {:ok, value} -> Application.put_env(:custyard, key, value)
          :error -> Application.delete_env(:custyard, key)
        end
      end
    end)

    for path <- [
          "/favicon.ico",
          "/live/websocket?vsn=2.0.0",
          "/live/longpoll?vsn=2.0.0",
          "/app/login"
        ] do
      result = Endpoint.call(conn(:get, path), Endpoint.init([]))
      assert result.status == 403
      assert result.halted
      assert result.resp_body == "Forbidden"
    end
  end

  test "missing, wrong, duplicate, and misconfigured origin secrets fail closed" do
    request = conn(:get, "/app/login")

    for headers <- [
          [],
          [{"x-custyard-origin", "wrong"}],
          [{"x-custyard-origin", @secret}, {"x-custyard-origin", @secret}]
        ] do
      result = Proxy.call(%{request | req_headers: headers}, @bunny)
      assert result.status == 403
      assert get_req_header(result, "x-custyard-origin") == []
    end

    result =
      Proxy.call(
        put_req_header(request, "x-custyard-origin", @secret),
        Keyword.put(@bunny, :secret, nil)
      )

    assert result.status == 403
  end

  test "only exact GET/HEAD health probes bypass authentication" do
    for method <- [:get, :head] do
      refute Proxy.call(conn(method, "/api/health"), @bunny).halted
    end

    for {method, path} <- [
          {:post, "/api/health"},
          {:get, "/api/health?token=value"},
          {:get, "/api/health/"},
          {:get, "/api/health/other"}
        ] do
      assert Proxy.call(conn(method, path), @bunny).status == 403
    end
  end

  test "authenticated Bunny request trusts scheme, keeps visitor Host, and drops secrets/Fly headers" do
    result =
      conn(:get, "http://tenant.example/app/login")
      |> put_req_header("x-custyard-origin", @secret)
      |> put_req_header("fly-client-ip", "1.2.3.4")
      |> put_req_header("x-forwarded-proto", "https")
      |> put_req_header("x-forwarded-port", "1234")
      |> put_req_header("x-forwarded-host", "spoofed.example")
      |> Proxy.call(@bunny)

    refute result.halted
    assert result.scheme == :https
    assert result.port == 443
    assert result.host == "tenant.example"
    assert get_req_header(result, "x-custyard-origin") == []
    assert get_req_header(result, "fly-client-ip") == []
    assert get_req_header(result, "x-forwarded-port") == []
  end

  test "Bunny rejects malformed or duplicate forwarded scheme headers" do
    for values <- [["https,http"], ["https", "http"], ["attacker-value"]] do
      headers = [{"x-custyard-origin", @secret} | Enum.map(values, &{"x-forwarded-proto", &1})]
      request = %{conn(:get, "http://tenant.example/") | req_headers: headers}
      assert Proxy.call(request, @bunny).status == 400
    end
  end

  test "none provider ignores forwarded scheme and production redirects to visitor host" do
    result =
      conn(:get, "http://tenant.example/portal/opaque-token")
      |> put_req_header("x-forwarded-proto", "https")
      |> put_req_header("x-forwarded-host", "spoofed.example")
      |> Proxy.call(provider: :none, https_required: true)

    assert result.status == 301
    assert get_resp_header(result, "location") == ["https://tenant.example/portal/opaque-token"]
  end

  test "deployment HTTPS requirement is independent of mutable application environment" do
    original =
      for key <- [:env, :https_required], do: {key, Application.fetch_env(:custyard, key)}

    on_exit(fn ->
      for {key, value} <- original do
        case value do
          {:ok, value} -> Application.put_env(:custyard, key, value)
          :error -> Application.delete_env(:custyard, key)
        end
      end
    end)

    Application.put_env(:custyard, :env, :prod)
    Application.put_env(:custyard, :https_required, false)
    refute Proxy.call(conn(:get, "http://tenant.example/"), provider: :none).halted

    Application.put_env(:custyard, :env, :test)
    Application.put_env(:custyard, :https_required, true)
    assert Proxy.call(conn(:get, "http://tenant.example/"), provider: :none).status == 301
  end

  test "production authenticated HTTPS gets HSTS and HTTP health still works" do
    result =
      conn(:get, "http://tenant.example/")
      |> put_req_header("x-custyard-origin", @secret)
      |> put_req_header("x-forwarded-proto", "https")
      |> Proxy.call(Keyword.put(@bunny, :https_required, true))

    refute result.halted
    assert get_resp_header(result, "strict-transport-security") == ["max-age=31536000"]

    health =
      Proxy.call(
        conn(:get, "http://probe.internal/api/health"),
        Keyword.put(@bunny, :https_required, true)
      )

    refute health.halted
    assert health.scheme == :http
  end
end
