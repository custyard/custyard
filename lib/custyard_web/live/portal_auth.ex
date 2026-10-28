defmodule CustyardWeb.Live.PortalAuth do
  @moduledoc "Authenticates portal bearer credentials on mount and every LiveView event."
  import Phoenix.Component
  import Phoenix.LiveView
  alias Custyard.{PortalCredentials, Tenants}

  def on_mount(:default, params, _, socket) do
    socket = CustyardWeb.HostScope.capture(socket)

    with %{id: tenant_id} = tenant <- Tenants.resolve_host(socket.assigns.verified_host),
         token when is_binary(token) <- params["org_token"],
         {:ok, credential} <- PortalCredentials.authenticate(token, tenant_id) do
      path = "/portal/" <> token

      {:cont,
       socket
       |> assign(:current_org, credential.organization)
       |> assign(:current_tenant, tenant)
       |> assign(:portal_credential, credential)
       |> assign(:is_custom_domain, false)
       |> assign(:site_name, tenant.name)
       |> assign(:portal_branding, Tenants.branding(tenant))
       |> assign(:portal_path, path)
       |> assign(:portal_home_path, path)
       |> attach_hook(:portal_recheck, :handle_event, fn _, _, socket ->
         recheck(socket, token, tenant_id)
       end)
       |> attach_hook(:portal_recheck_info, :handle_info, fn _, socket ->
         recheck(socket, token, tenant_id)
       end)
       |> attach_hook(:portal_recheck_params, :handle_params, fn _, _, socket ->
         recheck(socket, token, tenant_id)
       end)
       |> attach_hook(:portal_recheck_async, :handle_async, fn _, _, socket ->
         recheck(socket, token, tenant_id)
       end)}
    else
      _ -> {:halt, redirect(socket, to: "/")}
    end
  end

  defp recheck(socket, token, tenant_id) do
    tenant = Tenants.resolve_host(socket.assigns.verified_host)

    if tenant && tenant.id == tenant_id &&
         match?({:ok, _}, PortalCredentials.authenticate(token, tenant_id)),
       do: {:cont, socket},
       else: {:halt, redirect(socket, to: "/")}
  end
end
