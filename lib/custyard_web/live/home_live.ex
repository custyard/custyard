defmodule CustyardWeb.HomeLive do
  use CustyardWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    tenant = socket.host_uri && Custyard.Tenants.resolve_host(socket.host_uri.host)
    {:ok, assign(socket, :current_tenant, tenant)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-xl py-12" data-testid="home-container">
      <.header class="text-center">
        <img
          :if={@current_tenant && @current_tenant.logo_url}
          src={@current_tenant.logo_url}
          alt=""
          class="h-16 w-auto mx-auto mb-4"
        />
        {if @current_tenant, do: "Welcome to #{@current_tenant.name}", else: "Welcome to Custyard"}
        <:subtitle>
          {if @current_tenant,
            do: "Support conversations, shared updates and follow-up tasks",
            else: "Customer management system"}
        </:subtitle>
      </.header>

      <div class="mt-8 text-center space-y-4">
        <.link
          navigate={~p"/app/login"}
          class="inline-block px-4 py-2 bg-indigo-600 text-white text-sm font-medium rounded hover:bg-indigo-700"
          data-testid="home-staff-login-link"
        >
          {if @current_tenant, do: "Staff sign in", else: "Staff sign in"}
        </.link>
        <p class="text-sm text-gray-500 dark:text-zinc-400" data-testid="home-portal-info">
          {if @current_tenant,
            do: "Customers: open the private conversation or portal link shared with you.",
            else: "Customer portals are accessed via your organization's dedicated URL."}
        </p>
      </div>
    </div>
    """
  end
end
