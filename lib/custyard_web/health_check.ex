defmodule CustyardWeb.HealthCheck do
  @moduledoc """
  SSL bypass for health check probes.

  Fly.io machine-level checks (`[checks]` in fly.toml) hit the app
  directly over HTTP, without proxy headers. Plug.SSL would redirect
  these to HTTPS, causing health checks to fail with 301 loops.

  Used as an MFA exclude in the `force_ssl` endpoint config so that
  the health path is accessible over plain HTTP for internal probes
  while all other traffic is still redirected to HTTPS.
  """

  @health_path Application.compile_env(:custyard, [:health_check, :path], "/api/health")

  @doc """
  Returns `true` for connections targeting the health check path,
  telling Plug.SSL to skip the HTTPS redirect.
  """
  def skip_ssl?(%Plug.Conn{request_path: path}) do
    path == @health_path
  end
end
