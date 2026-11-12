defmodule CustyardWeb.Staff.TasksLive do
  @moduledoc """
  Every task of the tenant in one list, whatever it is attached to.
  """

  use CustyardWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :page_title, "All tasks"), layout: {CustyardWeb.Layouts, :staff}}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-full max-w-6xl px-3 py-4 sm:px-4" data-testid="staff-tasks-page">
      <h1 class="text-lg font-semibold text-gray-900 dark:text-zinc-100">All tasks</h1>
    </div>
    """
  end
end
