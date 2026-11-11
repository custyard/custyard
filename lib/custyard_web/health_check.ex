defmodule CustyardWeb.HealthCheck do
  @moduledoc """
  The health probe paths that bypass the HTTPS redirect and, behind Bunny,
  origin authentication.

  Platform checks (`[checks]` in fly.toml, the Containerfile `HEALTHCHECK`,
  Bunny's container probes) hit the app directly over HTTP, without proxy
  headers. Plug.SSL would redirect these to HTTPS, causing health checks to
  fail with 301 loops, and the Bunny origin guard would refuse them.

  `CustyardWeb.Proxy.health_probe?/1` uses `skip_ssl?/1` (with its own method
  and query-string conditions) so the readiness and liveness paths answer
  internal probes over plain HTTP while all other traffic is authenticated
  and redirected to HTTPS.
  """

  @health_path Application.compile_env(:custyard, [:health_check, :path], "/api/health")
  @live_path Application.compile_env(:custyard, [:health_check, :live_path], "/api/health/live")

  @doc """
  Returns `true` for connections targeting the readiness or liveness
  path, telling Plug.SSL to skip the HTTPS redirect.
  """
  def skip_ssl?(%Plug.Conn{request_path: path}) do
    path in [@health_path, @live_path]
  end
end
