defmodule CustyardWeb.Plugs.CustomDomain do
  @moduledoc "Resolves tenant hosts while reserving the installation hostname for installation pages."
  import Plug.Conn
  alias Custyard.Tenants
  def init(opts), do: opts

  def call(conn, _) do
    cond do
      Tenants.normalize_host(conn.host) == Tenants.normalize_host(Tenants.app_host()) ->
        installation(conn)

      # Container platforms probe the port directly and cannot send a
      # registered hostname. The exact probe carries no tenant data and is the
      # same request the origin guard admits (CustyardWeb.Proxy).
      CustyardWeb.Proxy.health_probe?(conn) ->
        conn

      true ->
        workspace(conn, Tenants.resolve_host(conn.host))
    end
  end

  defp installation(conn) do
    if installation_request?(conn),
      do: assign(conn, :installation_host, true),
      else: conn |> send_resp(404, "Workspace hostname required") |> halt()
  end

  defp workspace(conn, tenant) do
    cond do
      admin_request?(conn) ->
        conn |> send_resp(404, "Installation hostname required") |> halt()

      tenant && callback_request?(conn) ->
        conn

      tenant && tenant.status == "active" ->
        conn |> assign(:host_tenant, tenant) |> assign(:current_tenant, tenant)

      tenant ->
        conn |> send_resp(403, "Workspace suspended") |> halt()

      true ->
        conn |> send_resp(404, "Unknown workspace host") |> halt()
    end
  end

  defp installation_request?(conn) do
    conn.request_path in ["/", "/api/health", "/api/health/live"] or
      admin_request?(conn) or callback_request?(conn) or
      development_request?(conn)
  end

  defp admin_request?(conn),
    do: conn.request_path == "/admin" or String.starts_with?(conn.request_path, "/admin/")

  defp development_request?(conn) do
    String.starts_with?(conn.request_path, "/dev/") and
      Application.get_env(:custyard, :env) == :dev
  end

  defp callback_request?(conn), do: String.starts_with?(conn.request_path, "/api/webhook/")
end
