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
        {:ok,
         socket
         |> assign(:project, project)
         |> assign(:page_title, project.title)}
    end
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

      <div class="bg-white border rounded-lg p-6 mb-6">
        <h1 class="text-2xl font-semibold text-gray-900 mb-2" data-testid="portal-project-title">
          {@project.title}
        </h1>
        <p
          :if={@project.description}
          class="text-gray-600 mb-4"
          data-testid="portal-project-description"
        >
          {@project.description}
        </p>

        <div
          class="flex items-center gap-6 text-sm text-gray-500 mb-4"
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

      <h2 class="text-lg font-semibold text-gray-900 mb-3" data-testid="portal-tasks-heading">
        Tasks
      </h2>

      <div
        :if={@project.tasks != []}
        class="bg-white border rounded-lg divide-y"
        data-testid="portal-tasks-list"
      >
        <%= for task <- @project.tasks do %>
          <div class="p-4 flex items-center gap-4" data-testid="portal-task-item">
            <.task_state_icon state={task.state} />
            <div class="flex-1">
              <div
                class={"text-gray-900 #{if task.state == :done, do: "line-through opacity-60"}"}
                data-testid="portal-task-title"
              >
                {task.title}
              </div>
              <div :if={task.due_at} class="text-sm text-gray-500" data-testid="portal-task-due">
                Due: {format_due_at(task.due_at)}
              </div>
            </div>
            <.task_state_badge state={task.state} />
          </div>
        <% end %>
      </div>

      <div
        :if={@project.tasks == []}
        class="text-center py-12 text-gray-500 bg-white border rounded-lg"
        data-testid="portal-empty-state"
      >
        No tasks in this project yet.
      </div>
    </div>
    """
  end

  attr :progress, :map, required: true

  defp progress_bar(assigns) do
    ~H"""
    <div data-testid="portal-project-progress-bar">
      <div class="flex justify-between text-sm text-gray-600 mb-2">
        <span>Progress: {@progress.done} of {@progress.total} tasks completed</span>
        <span>{@progress.percentage}%</span>
      </div>
      <div class="w-full bg-gray-200 rounded-full h-3">
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
          class="flex-shrink-0 w-6 h-6 rounded-full bg-green-100 flex items-center justify-center"
          data-testid={"portal-task-icon-#{@state}"}
        >
          <.icon name="hero-check" class="w-4 h-4 text-green-600" />
        </span>
      <% :in_progress -> %>
        <span
          class="flex-shrink-0 w-6 h-6 rounded-full bg-blue-100 flex items-center justify-center"
          data-testid={"portal-task-icon-#{@state}"}
        >
          <.icon name="hero-arrow-path" class="w-4 h-4 text-blue-600" />
        </span>
      <% _ -> %>
        <span
          class="flex-shrink-0 w-6 h-6 rounded-full bg-gray-100 flex items-center justify-center"
          data-testid={"portal-task-icon-#{@state}"}
        >
          <span class="w-2 h-2 rounded-full bg-gray-400" />
        </span>
    <% end %>
    """
  end

  attr :state, :atom, required: true

  defp task_state_badge(assigns) do
    {bg_color, text_color, label} =
      case assigns.state do
        :done -> {"bg-green-100", "text-green-800", "Done"}
        :in_progress -> {"bg-blue-100", "text-blue-800", "In Progress"}
        :open -> {"bg-gray-100", "text-gray-600", "Open"}
        _ -> {"bg-gray-100", "text-gray-600", "Open"}
      end

    assigns =
      assigns
      |> assign(:bg_color, bg_color)
      |> assign(:text_color, text_color)
      |> assign(:label, label)

    ~H"""
    <span
      class={"text-xs px-2 py-1 rounded #{@bg_color} #{@text_color}"}
      data-testid={"portal-task-badge-#{@state}"}
    >
      {@label}
    </span>
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
