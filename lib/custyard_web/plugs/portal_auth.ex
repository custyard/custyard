defmodule CustyardWeb.Plugs.PortalAuth do
  @moduledoc """
  Validates org access for portal routes.

  Handles two paths:
  1. Custom domain: org already assigned by CustomDomain plug (runs in endpoint)
  2. Token in URL: look up org by token from path params

  On success, assigns :current_org and stores org_id in session for LiveView access.
  On failure, renders 404 and halts.

  ## Security Considerations

  Currently, portal access is controlled solely by knowledge of the organization
  token (a 32-byte random base64 URL string). This is a "shared secret" model
  similar to magic links or shareable URLs. Anyone with the token can:

  - View all non-resolved conversations for the organization
  - Create new conversations
  - Reply to any conversation
  - View portal-visible tasks and projects

  ### Known Limitations

  1. **No per-user authentication**: There is no login, session-bound identity,
     or per-contact authentication. The token URL is the sole access credential.

  2. **Token leakage risk**: If the token URL is shared (via email forwarding,
     browser history, referrer headers, etc.), unauthorized access is possible.

  3. **No audit trail for portal actions**: Without user identity, it's not
     possible to attribute portal actions to specific individuals.

  ### Mitigations

  - Tokens are 256-bit random values (sufficient entropy against brute force)
  - Organizations can regenerate their portal token if compromised
  - Custom domains add a layer of obscurity (no token in URL)
  - HTTPS protects tokens in transit

  ### Future Improvements

  For organizations requiring stronger access control, consider implementing:
  - Magic link email authentication (send login link to verified contact email)
  - Portal user accounts with password authentication
  - OAuth/SSO integration for enterprise customers

  See `PortalUser` schema (when implemented) for per-user authentication.
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
        is_custom_domain = custom_domain?(conn)

        conn
        |> assign(:current_org, org)
        |> put_session(:portal_org_id, org.id)
        |> put_session(:portal_custom_domain, is_custom_domain)
    end
  end

  defp custom_domain?(conn) do
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
