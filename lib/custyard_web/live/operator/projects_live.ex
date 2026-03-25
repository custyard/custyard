defmodule CustyardWeb.Operator.ProjectsLive do
  use CustyardWeb, :live_view

  alias Custyard.{Organizations, Projects}

  @impl true
  def mount(_params, _session, socket) do
    organizations = Organizations.list_organizations()

    socket =
      socket
      |> assign(:organizations, organizations)
      |> assign(:filter_org, nil)
      |> assign(:show_form, false)
      |> assign(:editing_project, nil)
      |> assign(:form_data, default_form_data())
      |> load_projects()

    {:ok, socket, layout: {CustyardWeb.Layouts, :operator}}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter_org = params["org"]

    socket =
      socket
      |> assign(:filter_org, filter_org)
      |> load_projects()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter_org", %{"org" => org_id}, socket) do
    path = if org_id == "", do: ~p"/operator/projects", else: ~p"/operator/projects?org=#{org_id}"
    {:noreply, push_patch(socket, to: path)}
  end

  def handle_event("show_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_form, true)
     |> assign(:editing_project, nil)
     |> assign(:form_data, default_form_data())}
  end

  def handle_event("hide_form", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_form, false)
     |> assign(:editing_project, nil)}
  end

  def handle_event("edit_project", %{"id" => id}, socket) do
    project = Projects.get_project!(id)

    {:noreply,
     socket
     |> assign(:show_form, true)
     |> assign(:editing_project, project)
     |> assign(:form_data, %{
       title: project.title,
       description: project.description || "",
       organization_id: to_string(project.organization_id || ""),
       start_date: format_date(project.start_date),
       target_completion_date: format_date(project.target_completion_date),
       portal_visible: project.portal_visible
     })}
  end

  @form_fields ~w(title description organization_id start_date target_completion_date portal_visible)a
  def handle_event("validate_form", params, socket) do
    form_data = socket.assigns.form_data

    form_data =
      Enum.reduce(@form_fields, form_data, fn field, acc ->
        val = Map.get(params, to_string(field), "")
        val = if field == :portal_visible and is_binary(val), do: val == "true", else: val
        Map.put(acc, field, val)
      end)

    {:noreply, assign(socket, :form_data, form_data)}
  end

  def handle_event("save_project", _params, socket) do
    attrs = build_project_attrs(socket.assigns.form_data)

    result =
      case socket.assigns.editing_project do
        nil -> Projects.create_project(attrs)
        project -> Projects.update_project(project, attrs)
      end

    handle_save_result(result, socket)
  end

  def handle_event("delete_project", %{"id" => id}, socket) do
    project = Projects.get_project!(id)

    case Projects.delete_project(project) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Project deleted.")
         |> load_projects()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete project.")}
    end
  end

  defp handle_save_result({:ok, _project}, socket) do
    action = if socket.assigns.editing_project, do: "updated", else: "created"

    {:noreply,
     socket
     |> put_flash(:info, "Project #{action} successfully.")
     |> assign(:show_form, false)
     |> assign(:editing_project, nil)
     |> load_projects()}
  end

  defp handle_save_result({:error, changeset}, socket) do
    {:noreply, put_flash(socket, :error, "Failed to save: #{format_changeset_errors(changeset)}")}
  end

  defp build_project_attrs(form_data) do
    org_id = parse_org_id(form_data.organization_id)

    %{
      title: form_data.title,
      description: if(form_data.description == "", do: nil, else: form_data.description),
      organization_id: org_id,
      start_date: parse_date(form_data.start_date),
      target_completion_date: parse_date(form_data.target_completion_date),
      portal_visible: form_data.portal_visible,
      project_type: if(org_id == nil, do: :internal, else: :customer)
    }
  end

  defp parse_org_id(nil), do: nil
  defp parse_org_id(""), do: nil

  defp parse_org_id(str) do
    case Integer.parse(str) do
      {id, ""} -> id
      _ -> nil
    end
  end

  defp load_projects(socket) do
    projects =
      case socket.assigns.filter_org do
        nil ->
          Projects.list_for_operator()

        "" ->
          Projects.list_for_operator()

        org_id ->
          case Integer.parse(org_id) do
            {id, ""} -> Projects.list_for_organization(id)
            _ -> Projects.list_for_operator()
          end
      end

    assign(socket, :projects, projects)
  end

  defp default_form_data do
    %{
      title: "",
      description: "",
      organization_id: "",
      start_date: "",
      target_completion_date: "",
      portal_visible: true
    }
  end

  defp format_date(nil), do: ""
  defp format_date(date), do: Date.to_iso8601(date)

  defp parse_date(""), do: nil

  defp parse_date(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp format_changeset_errors(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(&format_error/1)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
  end

  defp format_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-4" data-testid="operator-projects-page">
      <div class="flex items-center justify-between mb-6">
        <h1
          class="text-lg font-semibold text-gray-900 dark:text-zinc-100"
          data-testid="operator-projects-heading"
        >
          Projects
        </h1>
        <button
          phx-click="show_form"
          class="bg-indigo-600 text-white text-sm px-4 py-2 rounded hover:bg-indigo-700"
          data-testid="operator-projects-add-btn"
        >
          Add project
        </button>
      </div>

      <div class="mb-4">
        <label for="org-filter" class="sr-only">Filter by organization</label>
        <select
          id="org-filter"
          phx-change="filter_org"
          name="org"
          class="border border-gray-300 dark:border-zinc-600 rounded px-3 py-2 text-sm"
          data-testid="operator-projects-org-filter"
        >
          <option value="">All organizations</option>
          <option
            :for={org <- @organizations}
            value={org.id}
            selected={@filter_org == to_string(org.id)}
          >
            {org.name}
          </option>
        </select>
      </div>

      <.project_form
        :if={@show_form}
        form_data={@form_data}
        editing={@editing_project != nil}
        organizations={@organizations}
      />

      <div class="space-y-2">
        <div
          :if={Enum.empty?(@projects)}
          class="text-center text-gray-400 dark:text-zinc-500 py-12"
          data-testid="operator-projects-empty"
        >
          No projects found.
        </div>
        <.project_card :for={project <- @projects} project={project} />
      </div>
    </div>
    """
  end

  attr :form_data, :map, required: true
  attr :editing, :boolean, required: true
  attr :organizations, :list, required: true

  defp project_form(assigns) do
    ~H"""
    <div
      id="project-form-card"
      phx-hook="ScrollIntoView"
      class="bg-white dark:bg-zinc-800 border border-gray-200 dark:border-zinc-700 rounded-lg p-4 mb-4"
      data-testid="operator-project-form-card"
    >
      <h2 class="text-sm font-semibold text-gray-900 dark:text-zinc-100 mb-4">
        {if @editing, do: "Edit project", else: "New project"}
      </h2>

      <form
        phx-change="validate_form"
        phx-submit="save_project"
        class="space-y-4"
        data-testid="operator-project-form"
      >
        <div>
          <label class="block text-sm font-medium text-gray-700 dark:text-zinc-300 mb-1">Title</label>
          <input
            type="text"
            name="title"
            value={@form_data.title}
            required
            phx-debounce="300"
            class="w-full border border-gray-300 dark:border-zinc-600 rounded px-3 py-2 text-sm"
            data-testid="operator-project-title-input"
          />
        </div>

        <div>
          <label class="block text-sm font-medium text-gray-700 dark:text-zinc-300 mb-1">
            Description
          </label>
          <textarea
            name="description"
            rows="3"
            phx-debounce="300"
            class="w-full border border-gray-300 dark:border-zinc-600 rounded px-3 py-2 text-sm"
            data-testid="operator-project-desc-input"
          >{@form_data.description}</textarea>
        </div>

        <div>
          <label class="block text-sm font-medium text-gray-700 dark:text-zinc-300 mb-1">
            Organization
          </label>
          <select
            name="organization_id"
            class="w-full border border-gray-300 dark:border-zinc-600 rounded px-3 py-2 text-sm"
            data-testid="operator-project-org-select"
          >
            <option value="">Internal project (no organization)</option>
            <option
              :for={org <- @organizations}
              value={org.id}
              selected={@form_data.organization_id == to_string(org.id)}
            >
              {org.name}
            </option>
          </select>
        </div>

        <div class="grid grid-cols-2 gap-4">
          <div>
            <label class="block text-sm font-medium text-gray-700 dark:text-zinc-300 mb-1">
              Start date
            </label>
            <input
              type="date"
              name="start_date"
              value={@form_data.start_date}
              class="w-full border border-gray-300 dark:border-zinc-600 rounded px-3 py-2 text-sm"
              data-testid="operator-project-start-date"
            />
          </div>
          <div>
            <label class="block text-sm font-medium text-gray-700 dark:text-zinc-300 mb-1">
              Target completion
            </label>
            <input
              type="date"
              name="target_completion_date"
              value={@form_data.target_completion_date}
              class="w-full border border-gray-300 dark:border-zinc-600 rounded px-3 py-2 text-sm"
              data-testid="operator-project-target-date"
            />
          </div>
        </div>

        <div class="flex items-center gap-2">
          <input type="hidden" name="portal_visible" value="false" />
          <input
            type="checkbox"
            id="portal_visible"
            name="portal_visible"
            checked={@form_data.portal_visible}
            value="true"
            class="rounded border-gray-300 dark:border-zinc-600"
            data-testid="operator-project-visible-checkbox"
          />
          <label for="portal_visible" class="text-sm text-gray-700 dark:text-zinc-300">
            Visible in client portal
          </label>
        </div>

        <div class="flex gap-2">
          <button
            type="submit"
            class="bg-indigo-600 text-white text-sm px-4 py-2 rounded hover:bg-indigo-700"
            data-testid="operator-project-submit-btn"
          >
            {if @editing, do: "Update", else: "Create"}
          </button>
          <button
            type="button"
            phx-click="hide_form"
            class="text-gray-600 dark:text-zinc-400 text-sm px-4 py-2 rounded hover:bg-gray-100 dark:hover:bg-zinc-700"
            data-testid="operator-project-cancel-btn"
          >
            Cancel
          </button>
        </div>
      </form>
    </div>
    """
  end

  attr :project, :map, required: true

  defp project_card(assigns) do
    ~H"""
    <div
      class="bg-white dark:bg-zinc-800 border border-gray-200 dark:border-zinc-700 rounded-lg p-4 hover:shadow-md transition-shadow"
      data-testid={"operator-project-card-#{@project.id}"}
    >
      <div class="flex items-start justify-between">
        <div class="flex-1">
          <div class="flex items-center gap-2 mb-1">
            <span
              class="font-semibold text-gray-900 dark:text-zinc-100"
              data-testid="operator-project-title"
            >
              {@project.title}
            </span>
            <.project_type_badge type={@project.project_type} />
            <span
              :if={not @project.portal_visible}
              class="text-xs px-1.5 py-0.5 rounded bg-gray-100 dark:bg-zinc-700 text-gray-500 dark:text-zinc-400"
            >
              hidden
            </span>
          </div>
          <div
            :if={@project.organization}
            class="text-sm text-gray-500 dark:text-zinc-400 mb-2"
            data-testid="operator-project-org"
          >
            {@project.organization.name}
          </div>
          <div
            :if={@project.description}
            class="text-sm text-gray-600 dark:text-zinc-400 mb-2 line-clamp-2"
            data-testid="operator-project-desc"
          >
            {@project.description}
          </div>
          <div class="flex items-center gap-4 text-xs text-gray-400 dark:text-zinc-500">
            <span :if={@project.start_date}>
              Start: {Date.to_iso8601(@project.start_date)}
            </span>
            <span :if={@project.target_completion_date}>
              Target: {Date.to_iso8601(@project.target_completion_date)}
            </span>
          </div>
        </div>

        <div class="flex items-center gap-2 ml-4">
          <.progress_ring progress={@project.progress} />
        </div>
      </div>

      <div class="flex items-center gap-2 mt-3 pt-3 border-t border-gray-100 dark:border-zinc-700">
        <button
          phx-click="edit_project"
          phx-value-id={@project.id}
          class="text-xs text-gray-500 dark:text-zinc-400 hover:text-gray-700 dark:hover:text-zinc-200 px-2 py-1 rounded hover:bg-gray-100 dark:hover:bg-zinc-700"
          data-testid={"operator-project-edit-#{@project.id}"}
        >
          Edit
        </button>
        <button
          phx-click="delete_project"
          phx-value-id={@project.id}
          data-confirm="Are you sure you want to delete this project?"
          class="text-xs text-red-500 hover:text-red-700 px-2 py-1 rounded hover:bg-red-50"
          data-testid={"operator-project-delete-#{@project.id}"}
        >
          Delete
        </button>
        <span
          class="text-xs text-gray-400 dark:text-zinc-500 ml-auto"
          data-testid="operator-project-task-count"
        >
          {@project.progress.done}/{@project.progress.total} tasks
        </span>
      </div>
    </div>
    """
  end

  attr :type, :atom, required: true

  defp project_type_badge(assigns) do
    colors =
      case assigns.type do
        :customer -> "text-blue-700 bg-blue-50"
        :internal -> "text-purple-700 bg-purple-50"
        _ -> "text-gray-600 dark:text-zinc-400 bg-gray-50 dark:bg-zinc-800"
      end

    assigns = assign(assigns, :colors, colors)

    ~H"""
    <span
      class={"text-xs px-1.5 py-0.5 rounded #{@colors}"}
      data-testid={"operator-project-type-#{@type}"}
    >
      {to_string(@type)}
    </span>
    """
  end

  attr :progress, :map, required: true

  defp progress_ring(assigns) do
    percentage = assigns.progress.percentage

    stroke_dasharray = 2 * :math.pi() * 16
    stroke_dashoffset = stroke_dasharray * (1 - percentage / 100)

    assigns =
      assigns
      |> assign(:stroke_dasharray, stroke_dasharray)
      |> assign(:stroke_dashoffset, stroke_dashoffset)

    ~H"""
    <div class="relative w-12 h-12" data-testid="operator-project-progress">
      <svg
        class="w-full h-full transform -rotate-90"
        viewBox="0 0 36 36"
        role="img"
        aria-label={"Progress: #{@progress.percentage}%"}
      >
        <circle
          cx="18"
          cy="18"
          r="16"
          fill="none"
          stroke="#e5e7eb"
          stroke-width="3"
        />
        <circle
          cx="18"
          cy="18"
          r="16"
          fill="none"
          stroke="#4f46e5"
          stroke-width="3"
          stroke-linecap="round"
          stroke-dasharray={@stroke_dasharray}
          stroke-dashoffset={@stroke_dashoffset}
        />
      </svg>
      <div class="absolute inset-0 flex items-center justify-center">
        <span class="text-xs font-medium text-gray-700 dark:text-zinc-300">
          {@progress.percentage}%
        </span>
      </div>
    </div>
    """
  end
end
