defmodule CustyardWeb.Portal.Helpers do
  @moduledoc """
  Helper functions shared across portal LiveViews.

  Handles both standard portal routes (/p/:org_token/...) and
  custom domain routes (support.acme.com/...).
  """

  import Phoenix.Component, only: [assign: 3]
  alias Custyard.Repo

  @doc """
  Get organization from params or socket assigns.
  Supports both URL-based org token and custom domain assignment.

  Returns `{:ok, organization}` or `{:error, :not_found}`.
  """
  def get_organization(%{"org_token" => token}, _socket) do
    case Repo.get_by(Custyard.Organization, token: token) do
      nil -> {:error, :not_found}
      org -> {:ok, org}
    end
  end

  def get_organization(_params, socket) do
    # Custom domain - org should be assigned by the plug
    case socket.assigns[:organization] do
      nil -> {:error, :not_found}
      org -> {:ok, org}
    end
  end

  @doc """
  Check if we're on a custom domain (vs standard /p/:token route).
  """
  def custom_domain?(socket) do
    Map.get(socket.assigns, :custom_domain_request, false)
  end

  @doc """
  Assign portal base path based on whether we're on a custom domain.
  Call this in mount after assigning :org.

  For custom domains, URLs should be root-relative (e.g., "/request/1")
  For standard routes, URLs include the token prefix (e.g., "/p/:token/request/1")

  Assigns:
  - `:portal_path` - Base path prefix for building sub-paths (empty string for custom domains)
  - `:portal_home_path` - Path to the portal home/list page (use this for navigation)
  - `:is_custom_domain` - Boolean flag for custom domain detection

  Note: Uses string interpolation instead of verified routes (~p"...") because custom
  domains require dynamic path prefixes determined at runtime, not compile-time.
  """
  def assign_portal_path(socket) do
    is_custom_domain = custom_domain?(socket)

    {base_path, home_path} =
      if is_custom_domain do
        {"", "/"}
      else
        token_path = "/p/#{socket.assigns.org.token}"
        {token_path, token_path}
      end

    socket
    |> assign(:portal_path, base_path)
    |> assign(:portal_home_path, home_path)
    |> assign(:is_custom_domain, is_custom_domain)
  end

  @doc """
  Generate a portal-relative path.
  Works with both standard routes and custom domains.
  """
  def portal_path(socket_or_assigns, path) do
    base =
      case socket_or_assigns do
        %Phoenix.LiveView.Socket{assigns: assigns} -> assigns.portal_path
        assigns when is_map(assigns) -> assigns.portal_path
      end

    "#{base}#{path}"
  end
end
