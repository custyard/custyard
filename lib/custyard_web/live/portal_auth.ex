defmodule CustyardWeb.Live.PortalAuth do
  @moduledoc """
  LiveView on_mount hook for portal authentication.

  Reads the org_id from session (set by PortalAuth plug) and validates it
  matches the org_token from the URL. This prevents session/URL divergence
  when users navigate to a different org's portal URL.

  Also handles custom domain detection for URL generation.
  """

  import Phoenix.Component, only: [assign: 3]
  alias Custyard.{Organization, Repo}

  def on_mount(:default, params, session, socket) do
    with id when not is_nil(id) <- session["portal_org_id"],
         %Organization{} = org <- Repo.get(Organization, id) do
      mount_organization(org, params, session, socket)
    else
      _ -> {:halt, Phoenix.LiveView.redirect(socket, to: "/")}
    end
  end

  defp mount_organization(org, params, session, socket) do
    custom_domain? = session["portal_custom_domain"] || false

    host_allowed? =
      is_nil(session["host_tenant_id"]) or session["host_tenant_id"] == org.tenant_id

    token_allowed? = is_nil(params["org_token"]) or org.token == params["org_token"]

    cond do
      not host_allowed? ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/")}

      not token_allowed? ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/p/#{org.token}")}

      true ->
        {:cont,
         socket
         |> assign(:current_org, org)
         |> assign(:is_custom_domain, custom_domain?)
         |> assign(:site_name, org.name)
         |> assign(:portal_branding, portal_branding(org))
         |> assign_portal_paths(org, custom_domain?)}
    end
  end

  # Generate portal navigation paths based on domain type.
  defp portal_branding(%{tenant_id: 1} = org), do: org

  defp portal_branding(org),
    do: Custyard.Tenants.branding(Custyard.Tenants.get_tenant!(org.tenant_id))

  # Custom domains get an empty prefix, so appending /new yields /new rather
  # than the protocol-relative URL //new.
  # Standard access gets token-prefixed paths (/p/:token).
  defp assign_portal_paths(socket, org, is_custom_domain) do
    if is_custom_domain do
      # Custom domain: preserve the host without exposing the org token. The
      # list is /requests rather than / (the app host's home page owns /).
      socket
      |> assign(:portal_path, "")
      |> assign(:portal_home_path, "/requests")
    else
      # Standard access: use token-prefixed paths
      token_path = "/p/#{org.token}"

      socket
      |> assign(:portal_path, token_path)
      |> assign(:portal_home_path, token_path)
    end
  end
end
