defmodule CustyardWeb.Plugs.CustomDomain do
  @moduledoc "Resolves registered tenant hosts. The installation console uses the configured host."
  import Plug.Conn
  alias Custyard.Tenants
  def init(opts), do: opts

  def call(conn, _) do
    tenant = Tenants.resolve_host(conn.host)

    installation? =
      Tenants.normalize_host(conn.host) == Tenants.normalize_host(Tenants.app_host())

    cond do
      console_request?(conn, installation?) ->
        assign(conn, :installation_host, true)

      development_request?(conn, installation?) ->
        conn

      callback_request?(conn, installation?, tenant) ->
        conn

      tenant && tenant.status == "active" ->
        conn |> assign(:host_tenant, tenant) |> assign(:current_tenant, tenant)

      tenant ->
        conn |> send_resp(403, "Workspace suspended") |> halt()

      installation_root?(conn, installation?) ->
        conn |> Phoenix.Controller.redirect(to: "/admin") |> halt()

      true ->
        conn |> send_resp(404, "Unknown workspace host") |> halt()
    end
  end

  defp installation_root?(conn, installation?), do: installation? and conn.request_path == "/"

  defp console_request?(conn, installation?) do
    installation? and
      (conn.request_path == "/admin" or String.starts_with?(conn.request_path, "/admin/") or
         conn.request_path == "/api/health")
  end

  defp development_request?(conn, installation?) do
    installation? and String.starts_with?(conn.request_path, "/dev/") and
      Application.get_env(:custyard, :env) == :dev
  end

  defp callback_request?(conn, installation?, tenant) do
    (installation? or not is_nil(tenant)) and
      String.starts_with?(conn.request_path, "/api/webhook/")
  end
end
