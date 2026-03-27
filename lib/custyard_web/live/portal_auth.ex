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
    org_id = session["portal_org_id"]
    is_custom_domain = session["portal_custom_domain"] || false
    url_token = params["org_token"]

    case org_id do
      nil ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/")}

      _ ->
        case Repo.get(Organization, org_id) do
          nil ->
            {:halt, Phoenix.LiveView.redirect(socket, to: "/")}

          org ->
            # Validate URL token matches session org (unless on custom domain)
            # This prevents confusion when session org differs from URL org
            if is_custom_domain or is_nil(url_token) or org.token == url_token do
              {:cont,
               socket
               |> assign(:current_org, org)
               |> assign(:is_custom_domain, is_custom_domain)
               # White-label: use org name in page titles and browser chrome
               |> assign(:site_name, org.name)
               |> assign_portal_paths(org, is_custom_domain)}
            else
              # URL token doesn't match session - redirect to correct portal
              {:halt, Phoenix.LiveView.redirect(socket, to: "/p/#{url_token}")}
            end
        end
    end
  end

  # Always use token-based paths. Custom domain path rewriting (/ instead of
  # /p/:token) requires a CustomDomain plug + router scope that don't exist yet.
  # When that lands, this function can branch on is_custom_domain again.
  defp assign_portal_paths(socket, org, _is_custom_domain) do
    token_path = "/p/#{org.token}"

    socket
    |> assign(:portal_path, token_path)
    |> assign(:portal_home_path, token_path)
  end
end
