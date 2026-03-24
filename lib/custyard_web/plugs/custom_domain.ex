defmodule CustyardWeb.Plugs.CustomDomain do
  @moduledoc """
  Plug that resolves custom domains to organizations for white-label portals.

  When a request comes in on a custom domain (e.g., support.acme.com), this plug
  looks up the organization by custom_domain and assigns it to the connection.

  This plug should be called early in the pipeline (in endpoint.ex) to allow
  route matching to work correctly with custom domains.
  """
  import Plug.Conn
  alias Custyard.{Repo, Organization}

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
        rewritten_path = "/p/#{org.token}#{conn.request_path}"

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
