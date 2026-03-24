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
  """
  def get_organization(%{"org_token" => token}, _socket) do
    Repo.get_by!(Custyard.Organization, token: token)
  end

  def get_organization(_params, socket) do
    # Custom domain - org should be assigned by the plug
    case socket.assigns[:organization] do
      nil -> raise "Organization not found for custom domain"
      org -> org
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
  """
  def assign_portal_path(socket) do
    is_custom_domain = custom_domain?(socket)

    base_path =
      if is_custom_domain do
        ""
      else
        "/p/#{socket.assigns.org.token}"
      end

    socket
    |> assign(:portal_path, base_path)
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
