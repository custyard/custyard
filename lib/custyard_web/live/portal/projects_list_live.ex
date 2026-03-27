defmodule CustyardWeb.Portal.ProjectsListLive do
  use CustyardWeb, :live_view

  alias Custyard.Projects

  @impl true
  def mount(_params, _session, socket) do
    # :current_org, :portal_path, :portal_home_path set by PortalAuth on_mount
    org = socket.assigns.current_org

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Custyard.PubSub, "projects:org:#{org.id}")
    end

    {:ok,
     socket
     |> assign(:page_title, "Projects")
     |> load_projects()}
  end

  @impl true
  def handle_info({:project_updated, _id}, socket) do
    {:noreply, load_projects(socket)}
  end

  def handle_info({:project_created, _id}, socket) do
    {:noreply, load_projects(socket)}
  end

  # Catch-all for unexpected PubSub messages to prevent LiveView crashes
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp load_projects(socket) do
    org = socket.assigns.current_org
    projects = Projects.list_portal_visible(org.id)
    assign(socket, :projects, projects)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-8 px-4" data-testid="portal-projects-list">
      <div class="flex justify-between items-center mb-6">
        <div>
          <h1
            class="text-2xl font-semibold text-gray-900 dark:text-zinc-100"
            data-testid="portal-projects-heading"
          >
            Projects
          </h1>
          <p class="text-sm text-gray-500 dark:text-zinc-400 mt-1">
            Active projects and their progress
          </p>
        </div>
        <.link
          navigate={@portal_home_path}
          class="text-indigo-600 hover:text-indigo-800"
          data-testid="portal-nav-requests"
        >
          View Requests
        </.link>
      </div>

      <div class="space-y-4">
        <.link
          :for={project <- @projects}
          navigate={"#{@portal_path}/projects/#{project.id}"}
          class="block"
          data-testid={"portal-project-item-#{project.id}"}
        >
          <div class="bg-white dark:bg-zinc-800 border dark:border-zinc-700 rounded-lg p-4 hover:border-indigo-300 transition-colors">
            <div class="flex justify-between items-start mb-3">
              <div>
                <h3
                  class="font-medium text-gray-900 dark:text-zinc-100"
                  data-testid="portal-project-title"
                >
                  {project.title}
                </h3>
                <p
                  :if={project.description}
                  class="text-sm text-gray-500 dark:text-zinc-400 mt-1 line-clamp-2"
                  data-testid="portal-project-description"
                >
                  {project.description}
                </p>
              </div>
              <.progress_badge progress={project.progress} />
            </div>

            <div
              class="flex items-center gap-4 text-sm text-gray-500 dark:text-zinc-400"
              data-testid="portal-project-dates"
            >
              <span :if={project.start_date}>
                Started: {format_date(project.start_date)}
              </span>
              <span :if={project.target_completion_date}>
                Target: {format_date(project.target_completion_date)}
              </span>
            </div>

            <.progress_bar progress={project.progress} />
          </div>
        </.link>

        <div
          :if={@projects == []}
          class="text-center py-12 text-gray-500 dark:text-zinc-400"
          data-testid="portal-empty-state"
        >
          No active projects at this time.
        </div>
      </div>
    </div>
    """
  end

  attr :progress, :map, required: true

  defp progress_badge(assigns) do
    ~H"""
    <span class="text-sm text-gray-600 dark:text-zinc-400" data-testid="portal-progress-badge">
      {@progress.done}/{@progress.total} tasks
    </span>
    """
  end

  attr :progress, :map, required: true

  defp progress_bar(assigns) do
    ~H"""
    <div class="mt-3" data-testid="portal-progress-bar">
      <div class="flex justify-between text-xs text-gray-500 dark:text-zinc-400 mb-1">
        <span>Progress</span>
        <span>{@progress.percentage}%</span>
      </div>
      <div class="w-full bg-gray-200 dark:bg-zinc-700 rounded-full h-2">
        <div
          class="bg-indigo-600 h-2 rounded-full transition-all duration-300"
          style={"width: #{@progress.percentage}%"}
        />
      </div>
    </div>
    """
  end

  defp format_date(date) do
    Calendar.strftime(date, "%b %d, %Y")
  end
end
