defmodule CustyardWeb.Plugs.CustomDomain do
  @moduledoc """
  Plug that resolves custom domains to organizations for white-label portals.

  When a request comes in on a custom domain (e.g., support.acme.com), this plug
  looks up the organization by custom_domain and assigns it to the connection.

  This plug should be called early in the pipeline (in endpoint.ex) to allow
  route matching to work correctly with custom domains.

  ## Security Notes

  - **Host header trust**: This plug trusts the Host header for domain matching.
    Organizations must explicitly configure their custom_domain in settings.
    An attacker pointing arbitrary DNS at the server would need to guess an
    existing configured custom_domain, and would only access the public portal.

  - **Path rewriting**: This plug directly modifies `conn.request_path` and
    `conn.path_info` to inject the organization token. This is intentional and
    required for router matching. The original path is preserved in the
    rewritten URL structure (`/p/:token/original/path`).

  - **Path rewriting concern (accepted risk)**: The plug rewrites request paths
    based on custom_domain database lookups without an explicit domain allowlist.
    This was analyzed and accepted because:

    1. **Limited impact** - only affects public portal routes (no auth bypass)
    2. **Attack requires knowledge** - attacker must know a valid configured custom_domain
    3. **Additional protection** - org.token provides protection for route matching
    4. **Infrastructure-level mitigation** - TLS SNI validation or reverse proxy
       (Fly.io, nginx) should validate Host headers against its config

    This is not traditional SSRF (no outbound requests to attacker-controlled URLs),
    but a path-rewriting concern where untrusted Host headers could influence routing.
    The proper fix is infrastructure-level Host header validation, not application code.
  """
  require Custyard.Log, as: Log

  import Plug.Conn
  alias Custyard.{Organization, Repo}

  @behaviour Plug

  def init(opts), do: opts

  def call(conn, _opts) do
    host = conn.host

    # Skip if this is a known app host (configured in endpoint)
    app_hosts = get_app_hosts()

    if host in app_hosts do
      conn
    else
      resolve_custom_domain(conn, host)
    end
  end

  defp get_app_hosts do
    config = Application.get_env(:custyard, CustyardWeb.Endpoint, [])
    main_host = get_in(config, [:url, :host]) || "localhost"
    # Also allow localhost variations for development
    [main_host, "localhost", "127.0.0.1"]
  end

  defp resolve_custom_domain(conn, host) do
    # Hostnames are case-insensitive. Stored values are lowercase (normalized
    # on save, and by a migration for rows saved before that), so an exact
    # match on the lowercased host uses the unique index and finds at most
    # one organization.
    lowered = String.downcase(host)

    case Custyard.Tenants.resolve_host(lowered) do
      %Custyard.Tenant{} = tenant -> assign(conn, :host_tenant, tenant)
      nil -> resolve_legacy_domain(conn, lowered)
    end
  end

  defp resolve_legacy_domain(conn, lowered) do
    case Repo.get_by(Organization, custom_domain: lowered) do
      nil ->
        # Unknown host - let the request proceed normally
        # (may 404 or be handled by other routes)
        conn

      org ->
        rewrite_to_portal(conn, org)
    end
  end

  # Found org with this custom domain - rewrite the path onto the portal
  # routes under /p/:token so the HTTP request renders the portal.
  #
  # The browser keeps the un-prefixed URL, and that URL is what the LiveView
  # client sends on connect: the router has to resolve it to the same
  # LiveView and live_session as the dead render, or the connected mount is
  # refused and the page reloads forever. So the portal LiveViews also exist
  # at the root of the router (see CustyardWeb.Router): /request/:id, /new,
  # /projects, /projects/:id, and /requests for the list. "/" is the one
  # path the app host's home page already owns, so on a custom domain it
  # redirects to /requests.
  defp rewrite_to_portal(conn, org) do
    conn =
      conn
      |> assign(:organization, org)
      |> assign(:custom_domain_request, true)
      |> put_private(:custyard_custom_domain, true)

    case conn.request_path do
      "/" ->
        conn
        |> Phoenix.Controller.redirect(to: "/requests")
        |> halt()

      "/requests" ->
        put_path(conn, "/p/#{org.token}")

      "/p/" <> _ ->
        # Guard against double-prefix if path already starts with /p/
        Log.warning(:portal_path_already_prefixed)
        conn

      path ->
        put_path(conn, "/p/#{org.token}#{path}")
    end
  end

  defp put_path(conn, rewritten_path) do
    conn
    |> Map.put(:request_path, rewritten_path)
    |> Map.put(:path_info, String.split(rewritten_path, "/", trim: true))
  end

  @doc """
  Check if the current request is from a custom domain.
  """
  def custom_domain?(conn) do
    conn.private[:custyard_custom_domain] == true
  end
end
