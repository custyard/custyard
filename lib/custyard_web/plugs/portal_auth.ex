defmodule CustyardWeb.Plugs.PortalAuth do
  @moduledoc "Verifies a portal credential against the resolved tenant host."
  import Plug.Conn
  def init(opts), do: opts

  def call(conn, _) do
    with %{id: tenant_id} <- conn.assigns[:host_tenant],
         token when is_binary(token) <- conn.path_params["org_token"],
         {:ok, credential} <- Custyard.PortalCredentials.authenticate(token, tenant_id) do
      conn
      |> assign(:current_org, credential.organization)
      |> assign(:portal_credential, credential)
      |> assign(:portal_branding, Custyard.Tenants.branding(conn.assigns.host_tenant))
    else
      _ -> conn |> send_resp(404, "Portal unavailable") |> halt()
    end
  end
end
