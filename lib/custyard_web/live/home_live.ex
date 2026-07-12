defmodule CustyardWeb.HomeLive do
  use CustyardWeb, :live_view

  alias Custyard.{OperatorAccount, Repo}

  @impl true
  def mount(_params, session, socket) do
    # An authenticated operator landing on "/" goes straight to the
    # dashboard (attention queue). Same session discipline as
    # CustyardWeb.Live.OperatorAuth: the id must resolve to a live
    # operator row — a stale session keeps the public landing page
    # instead of bouncing through /operator's login redirect.
    if operator_session?(session) do
      {:ok, redirect(socket, to: ~p"/operator")}
    else
      {:ok, socket}
    end
  end

  defp operator_session?(%{"operator_id" => operator_id}) when not is_nil(operator_id) do
    Repo.get(OperatorAccount, operator_id) != nil
  end

  defp operator_session?(_session), do: false

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
