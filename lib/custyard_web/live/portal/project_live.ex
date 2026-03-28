defmodule CustyardWeb.Portal.ProjectLive do
  use CustyardWeb, :live_view

  alias Custyard.Projects

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    # :current_org, :portal_path, :portal_home_path set by PortalAuth on_mount
    org = socket.assigns.current_org

    case Projects.get_portal_project(id, org.id) do
      {:error, _} ->
        {:ok, push_navigate(socket, to: "#{socket.assigns.portal_path}/projects")}

      {:ok, project} ->
        if connected?(socket) do
          # Subscribe to project-specific updates (task changes, etc.)
          Phoenix.PubSub.subscribe(Custyard.PubSub, "project:#{project.id}")
        end

        {:ok,
         socket
         |> assign(:project, project)
         |> assign(:page_title, project.title)}
    end
  end

  @impl true
  def handle_info({:project_updated, _id}, socket) do
    # Reload the project to get updated task states
    case Projects.get_portal_project(socket.assigns.project.id, socket.assigns.current_org.id) do
      {:ok, project} ->
        {:noreply, assign(socket, :project, project)}

      {:error, _} ->
        # Project no longer accessible, redirect
        {:noreply, push_navigate(socket, to: "#{socket.assigns.portal_path}/projects")}
    end
  end

  # Catch-all for unexpected PubSub messages to prevent LiveView crashes
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-8 px-4" data-testid="portal-project-detail">
      <.link
        navigate={"#{@portal_path}/projects"}
        class="text-indigo-600 hover:text-indigo-800 mb-4 inline-block"
        data-testid="portal-back-link"
      >
        &larr; Back to projects
      </.link>

      <div class="bg-white dark:bg-zinc-800 border dark:border-zinc-700 rounded-lg p-6 mb-6">
        <h1
          class="text-2xl font-semibold text-gray-900 dark:text-zinc-100 mb-2"
          data-testid="portal-project-title"
        >
          {@project.title}
        </h1>
        <p
          :if={@project.description}
          class="text-gray-600 dark:text-zinc-400 mb-4"
          data-testid="portal-project-description"
        >
          {@project.description}
        </p>

        <div
          class="flex items-center gap-6 text-sm text-gray-500 dark:text-zinc-400 mb-4"
          data-testid="portal-project-dates"
        >
          <span :if={@project.start_date}>
            Started: {format_date(@project.start_date)}
          </span>
          <span :if={@project.target_completion_date}>
            Target: {format_date(@project.target_completion_date)}
          </span>
        </div>

        <.progress_bar progress={@project.progress} />
      </div>

      <h2
        class="text-lg font-semibold text-gray-900 dark:text-zinc-100 mb-3"
        data-testid="portal-tasks-heading"
      >
        Tasks
      </h2>

      <div
        :if={@project.tasks != []}
        class="bg-white dark:bg-zinc-800 border dark:border-zinc-700 rounded-lg divide-y dark:divide-zinc-700"
        data-testid="portal-tasks-list"
      >
        <div
          :for={task <- @project.tasks}
          class="p-4 flex items-center gap-4"
          data-testid="portal-task-item"
        >
          <.task_state_icon state={task.state} />
          <div class="flex-1">
            <div
              class={"text-gray-900 dark:text-zinc-100 #{if task.state == :done, do: "line-through opacity-60"}"}
              data-testid="portal-task-title"
            >
              {task.title}
            </div>
            <div
              :if={task.due_at}
              class="text-sm text-gray-500 dark:text-zinc-400"
              data-testid="portal-task-due"
            >
              Due: {format_due_at(task.due_at)}
            </div>
          </div>
          <.task_state_badge state={task.state} />
        </div>
      </div>

      <div
        :if={@project.tasks == []}
        class="text-center py-12 bg-white dark:bg-zinc-800 border dark:border-zinc-700 rounded-lg"
        data-testid="portal-empty-state"
      >
        <div class="text-gray-400 dark:text-zinc-500 mb-4">
          <svg
            class="mx-auto h-12 w-12"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            stroke-width="1"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M11.35 3.836c-.065.21-.1.433-.1.664 0 .414.336.75.75.75h4.5a.75.75 0 00.75-.75 2.25 2.25 0 00-.1-.664m-5.8 0A2.251 2.251 0 0113.5 2.25H15c1.012 0 1.867.668 2.15 1.586m-5.8 0c-.376.023-.75.05-1.124.08C9.095 4.01 8.25 4.973 8.25 6.108V8.25m8.9-4.414c.376.023.75.05 1.124.08 1.131.094 1.976 1.057 1.976 2.192V16.5A2.25 2.25 0 0118 18.75h-2.25m-7.5-10.5H4.875c-.621 0-1.125.504-1.125 1.125v11.25c0 .621.504 1.125 1.125 1.125h9.75c.621 0 1.125-.504 1.125-1.125V18.75m-7.5-10.5h6.375c.621 0 1.125.504 1.125 1.125v9.375m-8.25-3l1.5 1.5 3-3.75"
            />
          </svg>
        </div>
        <p class="text-gray-600 dark:text-zinc-400 text-sm">No tasks in this project yet.</p>
      </div>
    </div>
    """
  end

  attr :progress, :map, required: true

  defp progress_bar(assigns) do
    ~H"""
    <div data-testid="portal-project-progress-bar">
      <div class="flex justify-between text-sm text-gray-600 dark:text-zinc-400 mb-2">
        <span>Progress: {@progress.done} of {@progress.total} tasks completed</span>
        <span>{@progress.percentage}%</span>
      </div>
      <div class="w-full bg-gray-200 dark:bg-zinc-700 rounded-full h-3">
        <div
          class="bg-indigo-600 h-3 rounded-full transition-all duration-300"
          style={"width: #{@progress.percentage}%"}
        />
      </div>
    </div>
    """
  end

  attr :state, :atom, required: true

  defp task_state_icon(assigns) do
    ~H"""
    <%= case @state do %>
      <% :done -> %>
        <span
          class="shrink-0 w-6 h-6 rounded-full bg-green-100 flex items-center justify-center"
          data-testid={"portal-task-icon-#{@state}"}
        >
          <.icon name="hero-check" class="w-4 h-4 text-green-600" />
        </span>
      <% :in_progress -> %>
        <span
          class="shrink-0 w-6 h-6 rounded-full bg-blue-100 flex items-center justify-center"
          data-testid={"portal-task-icon-#{@state}"}
        >
          <.icon name="hero-arrow-path" class="w-4 h-4 text-blue-600" />
        </span>
      <% _ -> %>
        <span
          class="shrink-0 w-6 h-6 rounded-full bg-gray-100 dark:bg-zinc-700 flex items-center justify-center"
          data-testid={"portal-task-icon-#{@state}"}
        >
          <span class="w-2 h-2 rounded-full bg-gray-400 dark:bg-zinc-500" />
        </span>
    <% end %>
    """
  end

  defp format_date(date) do
    Calendar.strftime(date, "%b %d, %Y")
  end

  defp format_due_at(datetime) do
    now = DateTime.utc_now()
    diff_days = Date.diff(DateTime.to_date(datetime), DateTime.to_date(now))

    cond do
      diff_days < 0 -> "overdue"
      diff_days == 0 -> "today"
      diff_days == 1 -> "tomorrow"
      diff_days < 7 -> Calendar.strftime(datetime, "%A")
      true -> Calendar.strftime(datetime, "%b %d")
    end
  end
end
