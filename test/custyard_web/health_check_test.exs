defmodule CustyardWeb.HealthCheckTest do
  use ExUnit.Case, async: true

  alias CustyardWeb.HealthCheck

  test "skips the SSL redirect for the readiness and liveness paths" do
    assert HealthCheck.skip_ssl?(%Plug.Conn{request_path: "/api/health"})
    assert HealthCheck.skip_ssl?(%Plug.Conn{request_path: "/api/health/live"})
  end

  test "redirects everything else" do
    refute HealthCheck.skip_ssl?(%Plug.Conn{request_path: "/"})
    refute HealthCheck.skip_ssl?(%Plug.Conn{request_path: "/api/health/"})
    refute HealthCheck.skip_ssl?(%Plug.Conn{request_path: "/api/healthz"})
  end
end
