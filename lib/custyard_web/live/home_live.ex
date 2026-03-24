defmodule CustyardWeb.HomeLive do
  use CustyardWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-xl" data-testid="home-container">
      <.header class="text-center">
        Welcome to Custyard
        <:subtitle>
          Customer management system
        </:subtitle>
      </.header>
    </div>
    """
  end
end
