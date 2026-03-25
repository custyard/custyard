defmodule CustyardWeb.HomeLive do
  use CustyardWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-xl py-12" data-testid="home-container">
      <.header class="text-center">
        Welcome to Custyard
        <:subtitle>
          Customer management system
        </:subtitle>
      </.header>

      <div class="mt-8 text-center space-y-4">
        <.link
          navigate={~p"/operator/login"}
          class="inline-block px-4 py-2 bg-indigo-600 text-white text-sm font-medium rounded hover:bg-indigo-700"
          data-testid="home-operator-login-link"
        >
          Operator Login
        </.link>
        <p class="text-sm text-gray-500 dark:text-zinc-400" data-testid="home-portal-info">
          Customer portals are accessed via your organization's dedicated URL.
        </p>
      </div>
    </div>
    """
  end
end
