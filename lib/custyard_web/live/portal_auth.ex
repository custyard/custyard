defmodule CustyardWeb.Live.PortalAuth do
  @moduledoc """
  LiveView on_mount hook for portal authentication.

  Reads the org_id from session (set by PortalAuth plug) and assigns :current_org.
  Also handles custom domain detection for URL generation.
  """

  import Phoenix.Component, only: [assign: 3]
  alias Custyard.{Organization, Repo}

  def on_mount(:default, _params, session, socket) do
    org_id = session["portal_org_id"]
    is_custom_domain = session["portal_custom_domain"] || false

    case org_id do
      nil ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/")}

      _ ->
        case Repo.get(Organization, org_id) do
          nil ->
            {:halt, Phoenix.LiveView.redirect(socket, to: "/")}

          org ->
            {:cont,
             socket
             |> assign(:current_org, org)
             |> assign(:is_custom_domain, is_custom_domain)
             |> assign_portal_paths(org, is_custom_domain)}
        end
    end
  end

  defp assign_portal_paths(socket, _org, true = _is_custom_domain) do
    socket
    |> assign(:portal_path, "")
    |> assign(:portal_home_path, "/")
  end

  defp assign_portal_paths(socket, org, false = _is_custom_domain) do
    token_path = "/p/#{org.token}"

    socket
    |> assign(:portal_path, token_path)
    |> assign(:portal_home_path, token_path)
  end
end
