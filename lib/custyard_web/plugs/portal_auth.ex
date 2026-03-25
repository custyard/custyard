defmodule CustyardWeb.Plugs.PortalAuth do
  @moduledoc """
  Validates org access for portal routes.

  Handles two paths:
  1. Custom domain: org already assigned by CustomDomain plug (runs in endpoint)
  2. Token in URL: look up org by token from path params

  On success, assigns :current_org and stores org_id in session for LiveView access.
  On failure, renders 404 and halts.
  """

  import Plug.Conn
  alias Custyard.{Organization, Repo}

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_org(conn) do
      nil ->
        conn
        |> put_status(404)
        |> Phoenix.Controller.put_view(CustyardWeb.ErrorHTML)
        |> Phoenix.Controller.render("404.html")
        |> halt()

      org ->
        is_custom_domain = is_custom_domain?(conn)

        conn
        |> assign(:current_org, org)
        |> put_session(:portal_org_id, org.id)
        |> put_session(:portal_custom_domain, is_custom_domain)
    end
  end

  defp is_custom_domain?(conn) do
    Map.get(conn.assigns, :custom_domain_request, false) ||
      conn.private[:custyard_custom_domain] == true
  end

  # Custom domain path: org already resolved by CustomDomain plug
  defp get_org(%{assigns: %{organization: org}}) when not is_nil(org), do: org

  # Token in URL path
  defp get_org(conn) do
    case conn.path_params["org_token"] do
      nil -> nil
      token -> Repo.get_by(Organization, token: token)
    end
  end
end
