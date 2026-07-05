defmodule CustyardWeb.Operator.ProjectDetailLive do
  use CustyardWeb, :live_view

  alias Custyard.{Projects, Task}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Projects.get_project(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Project not found")
         |> push_navigate(to: ~p"/operator/projects")}

      project ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Custyard.PubSub, "project:#{project.id}")
        end

        {:ok,
         socket
         |> assign(:project, project)
         |> assign(:page_title, project.title)
         |> assign(:show_task_form, false)
         |> assign(:new_task_title, "")
         |> assign(:new_task_due_at, "")
         |> assign(:new_task_portal_visible, true)}
    end
  end

  @impl true
  def handle_info({:project_updated, _id}, socket) do
    project = Projects.get_project!(socket.assigns.project.id)
    {:noreply, assign(socket, :project, project)}
  end

  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_task_form", _params, socket) do
    {:noreply, assign(socket, :show_task_form, not socket.assigns.show_task_form)}
  end

  def handle_event("update_new_task", params, socket) do
    {:noreply,
     socket
     |> assign(:new_task_title, params["title"] || socket.assigns.new_task_title)
     |> assign(:new_task_due_at, params["due_at"] || socket.assigns.new_task_due_at)
     |> assign(:new_task_portal_visible, params["portal_visible"] == "true")}
  end

  def handle_event("add_task", params, socket) do
    project = socket.assigns.project

    due_at = parse_datetime(params["due_at"])

    attrs = %{
      title: params["title"],
      due_at: due_at,
      portal_visible: params["portal_visible"] == "true"
    }

    case Projects.create_task(project, attrs) do
      {:ok, _task} ->
        project = Projects.get_project!(project.id)

        {:noreply,
         socket
         |> assign(:project, project)
         |> assign(:show_task_form, false)
         |> assign(:new_task_title, "")
         |> assign(:new_task_due_at, "")
         |> assign(:new_task_portal_visible, true)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create task")}
    end
  end

  def handle_event("cycle_task_state", %{"id" => task_id}, socket) do
    task = Projects.get_task(task_id)

    if task do
      next_state = next_task_state(task.state)

      case Projects.update_task_state(task, next_state) do
        {:ok, _} ->
          project = Projects.get_project!(socket.assigns.project.id)
          {:noreply, assign(socket, :project, project)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to update task")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete_task", %{"id" => task_id}, socket) do
    task = Projects.get_task(task_id)

    if task do
      case Projects.delete_task(task) do
        {:ok, _} ->
          project = Projects.get_project!(socket.assigns.project.id)
          {:noreply, assign(socket, :project, project)}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Failed to delete task")}
      end
    else
      {:noreply, socket}
    end
  end

  defp next_task_state(:open), do: :in_progress
  defp next_task_state(:in_progress), do: :done
  defp next_task_state(:done), do: :open

  defp parse_datetime(""), do: nil
  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) do
    case NaiveDateTime.from_iso8601(str <> ":00") do
      {:ok, ndt} -> DateTime.from_naive!(ndt, "Etc/UTC")
      _ -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-8 px-4" data-testid="operator-project-detail">
      <.link
        navigate={~p"/operator/projects"}
        class="text-indigo-600 hover:text-indigo-800 mb-4 inline-block"
        data-testid="operator-back-link"
      >
        &larr; Back to projects
      </.link>

      <div class="bg-white dark:bg-zinc-800 border dark:border-zinc-700 rounded-lg p-6 mb-6">
        <div class="flex items-start justify-between mb-4">
          <div>
            <h1
              class="text-2xl font-semibold text-gray-900 dark:text-zinc-100"
              data-testid="operator-project-title"
            >
              {@project.title}
            </h1>
            <.project_type_badge type={@project.project_type} />
          </div>
          <.link
            navigate={~p"/operator/projects"}
            phx-click="edit_project"
            phx-value-id={@project.id}
            class="text-sm text-gray-500 hover:text-gray-700"
          >
            Edit
          </.link>
        </div>

        <p
          :if={@project.description}
          class="text-gray-600 dark:text-zinc-400 mb-4"
          data-testid="operator-project-description"
        >
          {@project.description}
        </p>

        <div class="flex items-center gap-6 text-sm text-gray-500 dark:text-zinc-400 mb-4">
          <span :if={@project.start_date} data-testid="operator-project-start-date">
            Started: {format_date(@project.start_date)}
          </span>
          <span :if={@project.target_completion_date} data-testid="operator-project-target-date">
            Target: {format_date(@project.target_completion_date)}
          </span>
        </div>

        <.progress_bar progress={@project.progress} />
      </div>

      <div class="flex items-center justify-between mb-3">
        <h2
          class="text-lg font-semibold text-gray-900 dark:text-zinc-100"
          data-testid="operator-tasks-heading"
        >
          Tasks ({@project.progress.total})
        </h2>
        <button
          :if={not @show_task_form}
          phx-click="toggle_task_form"
          class="text-sm text-indigo-600 hover:text-indigo-800"
          data-testid="operator-add-task-btn"
        >
          + Add task
        </button>
      </div>

      <%= if @show_task_form do %>
        <div class="bg-white dark:bg-zinc-800 border dark:border-zinc-700 rounded-lg p-4 mb-4">
          <form
            phx-submit="add_task"
            phx-change="update_new_task"
            class="space-y-3"
            data-testid="operator-task-form"
          >
            <input
              type="text"
              name="title"
              value={@new_task_title}
              placeholder="Task title..."
              aria-label="Task title"
              class="w-full border border-gray-300 dark:border-zinc-600 rounded px-3 py-2"
              autofocus
              data-testid="operator-task-title-input"
            />
            <div class="flex gap-4">
              <div class="flex-1">
                <label class="block text-sm text-gray-600 dark:text-zinc-400 mb-1">Due date</label>
                <input
                  type="datetime-local"
                  name="due_at"
                  value={@new_task_due_at}
                  class="w-full border border-gray-300 dark:border-zinc-600 rounded px-3 py-2"
                  data-testid="operator-task-due-input"
                />
              </div>
              <div class="flex items-end gap-2 pb-2">
                <input type="hidden" name="portal_visible" value="false" />
                <input
                  type="checkbox"
                  name="portal_visible"
                  value="true"
                  checked={@new_task_portal_visible}
                  id="new_task_portal_visible"
                  class="h-4 w-4"
                  data-testid="operator-task-visible-checkbox"
                />
                <label for="new_task_portal_visible" class="text-sm text-gray-600 dark:text-zinc-400">
                  Portal visible
                </label>
              </div>
            </div>
            <div class="flex gap-2">
              <button
                type="submit"
                class="bg-indigo-600 text-white px-4 py-2 rounded hover:bg-indigo-700"
                data-testid="operator-task-add-btn"
              >
                Add Task
              </button>
              <button
                type="button"
                phx-click="toggle_task_form"
                class="text-gray-500 dark:text-zinc-400 hover:text-gray-700 px-4 py-2"
                data-testid="operator-task-cancel-btn"
              >
                Cancel
              </button>
            </div>
          </form>
        </div>
      <% end %>

      <div
        :if={@project.tasks != []}
        class="bg-white dark:bg-zinc-800 border dark:border-zinc-700 rounded-lg divide-y dark:divide-zinc-700"
        data-testid="operator-tasks-list"
      >
        <.task_item :for={task <- sorted_tasks(@project.tasks)} task={task} />
      </div>

      <div
        :if={@project.tasks == []}
        class="text-center py-12 bg-white dark:bg-zinc-800 border dark:border-zinc-700 rounded-lg"
        data-testid="operator-empty-state"
      >
        <div class="text-gray-400 dark:text-zinc-500 mb-4">
          <.icon name="hero-clipboard-document-list" class="mx-auto h-12 w-12" />
        </div>
        <p class="text-gray-600 dark:text-zinc-400 text-sm">No tasks in this project yet.</p>
        <button
          phx-click="toggle_task_form"
          class="mt-4 text-indigo-600 hover:text-indigo-800 text-sm"
        >
          Add the first task
        </button>
      </div>
    </div>
    """
  end

  attr :task, Task, required: true

  defp task_item(assigns) do
    ~H"""
    <div
      class="p-4 flex items-center gap-4 hover:bg-gray-50 dark:hover:bg-zinc-750"
      data-testid={"operator-task-item-#{@task.id}"}
    >
      <button
        phx-click="cycle_task_state"
        phx-value-id={@task.id}
        class="shrink-0"
        title="Click to change state"
        data-testid={"operator-task-state-btn-#{@task.id}"}
      >
        <.task_state_icon state={@task.state} />
      </button>

      <div class="flex-1 min-w-0">
        <div
          class={"text-gray-900 dark:text-zinc-100 #{if @task.state == :done, do: "line-through opacity-60"}"}
          data-testid="operator-task-title"
        >
          {@task.title}
        </div>
        <div class="flex items-center gap-3 text-sm text-gray-500 dark:text-zinc-400">
          <span :if={@task.due_at} data-testid="operator-task-due">
            Due: {format_due_at(@task.due_at)}
          </span>
          <span
            :if={not @task.portal_visible}
            class="text-xs text-amber-600"
            title="Not visible in portal"
          >
            <.icon name="hero-eye-slash" class="w-3 h-3 inline" /> Hidden
          </span>
        </div>
      </div>

      <.task_state_badge state={@task.state} />

      <button
        phx-click="delete_task"
        phx-value-id={@task.id}
        data-confirm="Delete this task?"
        class="text-gray-400 hover:text-red-500 p-1"
        data-testid={"operator-task-delete-#{@task.id}"}
      >
        <.icon name="hero-trash" class="w-4 h-4" />
      </button>
    </div>
    """
  end

  attr :progress, :map, required: true

  defp progress_bar(assigns) do
    ~H"""
    <div data-testid="operator-project-progress-bar">
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
        <span class="w-6 h-6 rounded-full bg-green-100 flex items-center justify-center">
          <.icon name="hero-check" class="w-4 h-4 text-green-600" />
        </span>
      <% :in_progress -> %>
        <span class="w-6 h-6 rounded-full bg-blue-100 flex items-center justify-center">
          <.icon name="hero-arrow-path" class="w-4 h-4 text-blue-600" />
        </span>
      <% _ -> %>
        <span class="w-6 h-6 rounded-full bg-gray-100 dark:bg-zinc-700 flex items-center justify-center">
          <span class="w-2 h-2 rounded-full bg-gray-400 dark:bg-zinc-500" />
        </span>
    <% end %>
    """
  end

  attr :type, :atom, required: true

  defp project_type_badge(assigns) do
    {text, colors} =
      case assigns.type do
        :internal -> {"Internal", "text-purple-700 bg-purple-100"}
        _ -> {"Customer", "text-blue-700 bg-blue-100"}
      end

    assigns = assign(assigns, text: text, colors: colors)

    ~H"""
    <span class={"text-xs px-2 py-0.5 rounded #{@colors} mt-1 inline-block"}>
      {@text}
    </span>
    """
  end

  defp sorted_tasks(tasks) do
    Enum.sort_by(tasks, fn task ->
      state_order =
        case task.state do
          :in_progress -> 0
          :open -> 1
          :done -> 2
        end

      {state_order, task.inserted_at}
    end)
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
