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
  require Logger

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
    case Repo.get_by(Organization, custom_domain: host) do
      nil ->
        # Unknown host - let the request proceed normally
        # (may 404 or be handled by other routes)
        conn

      org ->
        # Found org with this custom domain - rewrite path to use portal routes
        # /          -> /p/:token
        # /request/1 -> /p/:token/request/1
        # /new       -> /p/:token/new
        # Guard against double-prefix if path already starts with /p/
        rewritten_path =
          if String.starts_with?(conn.request_path, "/p/") do
            Logger.warning(
              "CustomDomain plug received path already prefixed with /p/: #{conn.request_path}"
            )

            conn.request_path
          else
            "/p/#{org.token}#{conn.request_path}"
          end

        conn
        |> assign(:organization, org)
        |> assign(:custom_domain_request, true)
        |> put_private(:custyard_custom_domain, true)
        |> Map.put(:request_path, rewritten_path)
        |> Map.put(:path_info, String.split(rewritten_path, "/", trim: true))
    end
  end

  @doc """
  Check if the current request is from a custom domain.
  """
  def custom_domain?(conn) do
    conn.private[:custyard_custom_domain] == true
  end
end
