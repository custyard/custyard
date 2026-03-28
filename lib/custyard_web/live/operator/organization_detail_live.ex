defmodule CustyardWeb.Operator.OrganizationDetailLive do
  @moduledoc """
  Organization detail view showing conversations, contacts, projects, and routes.
  """
  use CustyardWeb, :live_view

  import CustyardWeb.OperatorComponents

  require Logger

  alias Custyard.{Conversations, Organizations, Projects, InboundRoutes, Authorization}
  alias Custyard.{InboundRoute, InboundRouteWebhook}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Organizations.get_organization(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Organization not found")
         |> redirect(to: ~p"/operator/organizations")}

      org ->
        socket =
          socket
          |> assign(:page_title, org.name)
          |> assign(:organization, org)
          |> assign(:tab, "conversations")
          |> assign(:can_manage_routes, false)
          |> load_tab_data(org, "conversations")

        {:ok, socket, layout: {CustyardWeb.Layouts, :operator}}
    end
  end

  @impl true
  def handle_params(%{"tab" => tab}, _uri, socket)
      when tab in ~w(conversations contacts projects routes) do
    socket =
      socket
      |> assign(:tab, tab)
      |> load_tab_data(socket.assigns.organization, tab)

    {:noreply, socket}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, socket}
  end

  defp load_tab_data(socket, org, "conversations") do
    conversations = Conversations.list_for_organization(org.id, include_resolved: true)
    assign(socket, :conversations, conversations)
  end

  defp load_tab_data(socket, org, "contacts") do
    contacts = Organizations.list_contacts(org.id)
    assign(socket, :contacts, contacts)
  end

  defp load_tab_data(socket, org, "projects") do
    projects = Projects.list_for_organization(org.id)
    assign(socket, :projects, projects)
  end

  defp load_tab_data(socket, org, "routes") do
    routes = InboundRoutes.list_for_organization(org.id)
    projects = Projects.list_for_organization(org.id)
    can_manage = Authorization.can_manage_organization?(socket.assigns.current_operator, org.id)
    general_route_count = Enum.count(routes, &(&1.route_type == :general))

    socket
    |> assign(:routes, routes)
    |> assign(:available_projects, projects)
    |> assign(:can_manage_routes, can_manage)
    |> assign(:general_route_count, general_route_count)
    |> assign(:show_create_route_form, false)
    |> assign(:confirm_delete_route_id, nil)
  end

  # --- Route Event Handlers ---

  @impl true
  def handle_event("show_create_route_form", _, socket) do
    if socket.assigns.can_manage_routes do
      {:noreply, assign(socket, :show_create_route_form, true)}
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to create routes")}
    end
  end

  def handle_event("hide_create_route_form", _, socket) do
    if socket.assigns.can_manage_routes do
      {:noreply, assign(socket, :show_create_route_form, false)}
    else
      {:noreply, socket}
    end
  end

  @valid_route_types Enum.map(InboundRoute.route_types(), &to_string/1)
  @valid_sources Enum.map(InboundRoute.sources(), &to_string/1)
  @valid_purposes Enum.map(InboundRouteWebhook.purposes(), &to_string/1)

  def handle_event(
        "create_route",
        %{"route_type" => route_type, "source" => source} = params,
        socket
      ) do
    if socket.assigns.can_manage_routes do
      with :ok <- validate_param(route_type, @valid_route_types, "route_type"),
           :ok <- validate_param(source, @valid_sources, "source") do
        org = socket.assigns.organization

        attrs = %{
          organization_id: org.id,
          route_type: String.to_existing_atom(route_type),
          source: String.to_existing_atom(source)
        }

        attrs =
          case params do
            %{"project_id" => project_id} when project_id != "" ->
              case parse_id(project_id) do
                {:ok, id} -> Map.put(attrs, :project_id, id)
                :error -> attrs
              end

            _ ->
              attrs
          end

        case InboundRoutes.create_route(attrs) do
          {:ok, _route} ->
            socket =
              socket
              |> put_flash(:info, "Route created successfully")
              |> load_tab_data(org, "routes")

            {:noreply, socket}

          {:error, %Ecto.Changeset{} = changeset} ->
            message =
              Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
              |> Enum.map_join(", ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)

            {:noreply, put_flash(socket, :error, "Failed to create route: #{message}")}

          {:error, reason} ->
            Logger.error("Failed to create route: #{inspect(reason)}")
            {:noreply, put_flash(socket, :error, "Failed to create route")}
        end
      else
        {:error, message} ->
          {:noreply, put_flash(socket, :error, message)}
      end
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to create routes")}
    end
  end

  def handle_event(
        "toggle_webhook",
        %{"route-id" => route_id, "purpose" => purpose, "enabled" => enabled},
        socket
      ) do
    if socket.assigns.can_manage_routes do
      with :ok <- validate_param(purpose, @valid_purposes, "purpose"),
           {:ok, id} <- parse_id(route_id) do
        org = socket.assigns.organization
        route = InboundRoutes.get_route!(id)

        if route.organization_id != org.id do
          Logger.warning(
            "Unauthorized webhook toggle on route #{route.id} by operator in org #{org.id}"
          )

          {:noreply, put_flash(socket, :error, "You do not have permission to manage this route")}
        else
          purpose_atom = String.to_existing_atom(purpose)

          result =
            case enabled do
              "true" -> InboundRoutes.enable_webhook(route, purpose_atom)
              "false" -> InboundRoutes.disable_webhook(route, purpose_atom)
              _ -> {:error, :invalid_enabled_value}
            end

          case result do
            {:ok, _webhook} ->
              {:noreply, load_tab_data(socket, org, "routes")}

            {:error, reason} ->
              Logger.error("Failed to toggle webhook: #{inspect(reason)}")
              {:noreply, put_flash(socket, :error, "Failed to toggle webhook")}
          end
        end
      else
        {:error, message} when is_binary(message) ->
          {:noreply, put_flash(socket, :error, message)}

        :error ->
          {:noreply, put_flash(socket, :error, "Invalid route ID")}
      end
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to manage webhooks")}
    end
  end

  def handle_event("confirm_delete_route", %{"id" => route_id}, socket) do
    case parse_id(route_id) do
      {:ok, id} -> {:noreply, assign(socket, :confirm_delete_route_id, id)}
      :error -> {:noreply, put_flash(socket, :error, "Invalid route ID")}
    end
  end

  def handle_event("cancel_delete_route", _, socket) do
    {:noreply, assign(socket, :confirm_delete_route_id, nil)}
  end

  def handle_event("delete_route", %{"id" => route_id}, socket) do
    if socket.assigns.can_manage_routes do
      case parse_id(route_id) do
        {:ok, id} ->
          org = socket.assigns.organization
          route = InboundRoutes.get_route!(id)

          if route.organization_id != org.id do
            Logger.warning(
              "Unauthorized delete on route #{route.id} by operator in org #{org.id}"
            )

            {:noreply,
             put_flash(socket, :error, "You do not have permission to manage this route")}
          else
            if InboundRoutes.is_last_general_route?(route) do
              {:noreply,
               put_flash(
                 socket,
                 :error,
                 "Cannot delete the last general route for this organization"
               )}
            else
              case InboundRoutes.delete_route(route) do
                {:ok, _} ->
                  socket =
                    socket
                    |> put_flash(:info, "Route deleted")
                    |> assign(:confirm_delete_route_id, nil)
                    |> load_tab_data(org, "routes")

                  {:noreply, socket}

                {:error, reason} ->
                  Logger.error("Failed to delete route: #{inspect(reason)}")
                  {:noreply, put_flash(socket, :error, "Failed to delete route")}
              end
            end
          end

        :error ->
          {:noreply, put_flash(socket, :error, "Invalid route ID")}
      end
    else
      {:noreply, put_flash(socket, :error, "You do not have permission to delete routes")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="h-full flex flex-col" data-testid="operator-org-detail">
      <%!-- Header --%>
      <div class="bg-white dark:bg-zinc-800 border-b border-gray-200 dark:border-zinc-700 px-4 py-4">
        <div class="flex items-center gap-4">
          <.link
            navigate={~p"/operator/organizations"}
            class="text-gray-500 dark:text-zinc-400 hover:text-gray-700 dark:hover:text-zinc-200"
            data-testid="org-detail-back"
          >
            <svg class="h-5 w-5" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M15 19l-7-7 7-7"
              />
            </svg>
          </.link>
          <div class="flex-1">
            <div class="flex items-center gap-3">
              <%= if @organization.logo_url do %>
                <img
                  src={@organization.logo_url}
                  alt={"#{@organization.name} logo"}
                  class="h-8 w-8 rounded object-cover"
                />
              <% end %>
              <h1
                class="text-xl font-semibold text-gray-900 dark:text-zinc-100"
                data-testid="org-detail-name"
              >
                {@organization.name}
              </h1>
              <.tier_badge tier={@organization.tier} />
            </div>
            <div class="mt-1 text-sm text-gray-600 dark:text-zinc-400 flex items-center gap-4">
              <%= if @organization.domain do %>
                <span data-testid="org-detail-domain">{@organization.domain}</span>
              <% end %>
              <%= if @organization.custom_domain do %>
                <span
                  class="text-indigo-600 dark:text-indigo-400"
                  data-testid="org-detail-custom-domain"
                >
                  {@organization.custom_domain}
                </span>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Tabs --%>
        <div class="mt-4 flex gap-4 border-b border-gray-200 dark:border-zinc-700 -mb-px">
          <.tab_link
            tab="conversations"
            current={@tab}
            patch={~p"/operator/organizations/#{@organization.id}?tab=conversations"}
          >
            Conversations
          </.tab_link>
          <.tab_link
            tab="contacts"
            current={@tab}
            patch={~p"/operator/organizations/#{@organization.id}?tab=contacts"}
          >
            Contacts
          </.tab_link>
          <.tab_link
            tab="projects"
            current={@tab}
            patch={~p"/operator/organizations/#{@organization.id}?tab=projects"}
          >
            Projects
          </.tab_link>
          <.tab_link
            tab="routes"
            current={@tab}
            patch={~p"/operator/organizations/#{@organization.id}?tab=routes"}
          >
            Routes
          </.tab_link>
        </div>
      </div>

      <%!-- Content --%>
      <div class="flex-1 overflow-auto p-4">
        <%= case @tab do %>
          <% "conversations" -> %>
            <.conversations_tab conversations={@conversations} />
          <% "contacts" -> %>
            <.contacts_tab contacts={@contacts} />
          <% "projects" -> %>
            <.projects_tab projects={@projects} />
          <% "routes" -> %>
            <.routes_tab
              routes={@routes}
              available_projects={@available_projects}
              can_manage={@can_manage_routes}
              show_create_form={@show_create_route_form}
              confirm_delete_route_id={@confirm_delete_route_id}
              organization={@organization}
              general_route_count={@general_route_count}
            />
        <% end %>
      </div>
    </div>
    """
  end

  attr :tab, :string, required: true
  attr :current, :string, required: true
  attr :patch, :string, required: true
  slot :inner_block, required: true

  defp tab_link(assigns) do
    ~H"""
    <.link
      patch={@patch}
      class={[
        "px-3 py-2 text-sm font-medium border-b-2 -mb-px transition-colors",
        if(@tab == @current,
          do: "border-indigo-600 text-indigo-600 dark:border-indigo-400 dark:text-indigo-400",
          else:
            "border-transparent text-gray-600 dark:text-zinc-400 hover:text-gray-900 dark:hover:text-zinc-200 hover:border-gray-300 dark:hover:border-zinc-600"
        )
      ]}
      data-testid={"org-tab-#{@tab}"}
    >
      {render_slot(@inner_block)}
    </.link>
    """
  end

  attr :conversations, :list, required: true

  defp conversations_tab(assigns) do
    ~H"""
    <div class="space-y-2" data-testid="org-conversations-list">
      <div
        :if={@conversations == []}
        class="text-center py-12"
        data-testid="org-conversations-empty"
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
              d="M8.625 12a.375.375 0 11-.75 0 .375.375 0 01.75 0zm0 0H8.25m4.125 0a.375.375 0 11-.75 0 .375.375 0 01.75 0zm0 0H12m4.125 0a.375.375 0 11-.75 0 .375.375 0 01.75 0zm0 0h-.375M21 12c0 4.556-4.03 8.25-9 8.25a9.764 9.764 0 01-2.555-.337A5.972 5.972 0 015.41 20.97a5.969 5.969 0 01-.474-.065 4.48 4.48 0 00.978-2.025c.09-.457-.133-.901-.467-1.226C3.93 16.178 3 14.189 3 12c0-4.556 4.03-8.25 9-8.25s9 3.694 9 8.25z"
            />
          </svg>
        </div>
        <p class="text-gray-600 dark:text-zinc-400 text-sm">No conversations yet.</p>
      </div>

      <.link
        :for={conv <- @conversations}
        navigate={~p"/operator/conversation/#{conv.id}"}
        class="block p-4 bg-white dark:bg-zinc-800 rounded-lg border border-gray-200 dark:border-zinc-700 hover:border-indigo-300 dark:hover:border-indigo-600 transition-colors"
        data-testid={"org-conversation-#{conv.id}"}
      >
        <div class="flex items-start justify-between">
          <div class="flex-1 min-w-0">
            <div class="font-medium text-gray-900 dark:text-zinc-100 truncate">
              {conv.subject || "No subject"}
            </div>
            <div class="text-sm text-gray-600 dark:text-zinc-400 mt-1">
              {if conv.contact, do: conv.contact.name || conv.contact.email, else: "Unknown contact"}
            </div>
          </div>
          <div class="ml-4 flex flex-col items-end gap-1">
            <.state_badge state={conv.state} />
            <span class="text-xs text-gray-500 dark:text-zinc-500">
              {Calendar.strftime(conv.updated_at, "%b %d, %Y")}
            </span>
          </div>
        </div>
      </.link>
    </div>
    """
  end

  attr :contacts, :list, required: true

  defp contacts_tab(assigns) do
    ~H"""
    <div class="space-y-2" data-testid="org-contacts-list">
      <div
        :if={@contacts == []}
        class="text-center py-12"
        data-testid="org-contacts-empty"
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
              d="M15 19.128a9.38 9.38 0 002.625.372 9.337 9.337 0 004.121-.952 4.125 4.125 0 00-7.533-2.493M15 19.128v-.003c0-1.113-.285-2.16-.786-3.07M15 19.128v.106A12.318 12.318 0 018.624 21c-2.331 0-4.512-.645-6.374-1.766l-.001-.109a6.375 6.375 0 0111.964-3.07M12 6.375a3.375 3.375 0 11-6.75 0 3.375 3.375 0 016.75 0zm8.25 2.25a2.625 2.625 0 11-5.25 0 2.625 2.625 0 015.25 0z"
            />
          </svg>
        </div>
        <p class="text-gray-600 dark:text-zinc-400 text-sm">No contacts yet.</p>
      </div>

      <div
        :for={contact <- @contacts}
        class="p-4 bg-white dark:bg-zinc-800 rounded-lg border border-gray-200 dark:border-zinc-700"
        data-testid={"org-contact-#{contact.id}"}
      >
        <div class="flex items-center justify-between">
          <div>
            <div class="font-medium text-gray-900 dark:text-zinc-100">
              {contact.name || "Unnamed contact"}
            </div>
            <div class="text-sm text-gray-600 dark:text-zinc-400">
              {contact.email}
            </div>
          </div>
          <div class="text-xs text-gray-500 dark:text-zinc-500">
            Added {Calendar.strftime(contact.inserted_at, "%b %d, %Y")}
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :projects, :list, required: true

  defp projects_tab(assigns) do
    ~H"""
    <div class="space-y-2" data-testid="org-projects-list">
      <div
        :if={@projects == []}
        class="text-center py-12"
        data-testid="org-projects-empty"
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
              d="M9 12h3.75M9 15h3.75M9 18h3.75m3 .75H18a2.25 2.25 0 002.25-2.25V6.108c0-1.135-.845-2.098-1.976-2.192a48.424 48.424 0 00-1.123-.08m-5.801 0c-.065.21-.1.433-.1.664 0 .414.336.75.75.75h4.5a.75.75 0 00.75-.75 2.25 2.25 0 00-.1-.664m-5.8 0A2.251 2.251 0 0113.5 2.25H15c1.012 0 1.867.668 2.15 1.586m-5.8 0c-.376.023-.75.05-1.124.08C9.095 4.01 8.25 4.973 8.25 6.108V8.25m0 0H4.875c-.621 0-1.125.504-1.125 1.125v11.25c0 .621.504 1.125 1.125 1.125h9.75c.621 0 1.125-.504 1.125-1.125V9.375c0-.621-.504-1.125-1.125-1.125H8.25zM6.75 12h.008v.008H6.75V12zm0 3h.008v.008H6.75V15zm0 3h.008v.008H6.75V18z"
            />
          </svg>
        </div>
        <p class="text-gray-600 dark:text-zinc-400 text-sm">No projects yet.</p>
      </div>

      <.link
        :for={project <- @projects}
        navigate={~p"/operator/projects"}
        class="block p-4 bg-white dark:bg-zinc-800 rounded-lg border border-gray-200 dark:border-zinc-700 hover:border-indigo-300 dark:hover:border-indigo-600 transition-colors"
        data-testid={"org-project-#{project.id}"}
      >
        <div class="flex items-start justify-between">
          <div class="flex-1 min-w-0">
            <div class="font-medium text-gray-900 dark:text-zinc-100">
              {project.title}
            </div>
            <%= if project.description do %>
              <div class="text-sm text-gray-600 dark:text-zinc-400 mt-1 line-clamp-2">
                {project.description}
              </div>
            <% end %>
          </div>
          <div class="ml-4 text-xs text-gray-500 dark:text-zinc-500">
            {length(project.tasks)} tasks
          </div>
        </div>
      </.link>
    </div>
    """
  end

  # --- Routes Tab ---

  attr :routes, :list, required: true
  attr :available_projects, :list, required: true
  attr :can_manage, :boolean, required: true
  attr :show_create_form, :boolean, required: true
  attr :confirm_delete_route_id, :any, required: true
  attr :organization, :map, required: true
  attr :general_route_count, :integer, required: true

  defp routes_tab(assigns) do
    ~H"""
    <div class="space-y-4" data-testid="org-routes-list">
      <%!-- Header with create button --%>
      <div :if={@can_manage} class="flex justify-end">
        <button
          :if={not @show_create_form}
          phx-click="show_create_route_form"
          class="px-3 py-1.5 text-sm font-medium text-white bg-indigo-600 hover:bg-indigo-700 rounded-md transition-colors"
          data-testid="create-route-btn"
        >
          New Route
        </button>
      </div>

      <%!-- Create route form --%>
      <div
        :if={@show_create_form and @can_manage}
        class="p-4 bg-white dark:bg-zinc-800 rounded-lg border border-indigo-300 dark:border-indigo-600"
        data-testid="create-route-form"
      >
        <h3 class="text-sm font-medium text-gray-900 dark:text-zinc-100 mb-3">Create New Route</h3>
        <form phx-submit="create_route" class="space-y-3">
          <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
            <div>
              <label class="block text-xs font-medium text-gray-700 dark:text-zinc-300 mb-1">
                Route Type
              </label>
              <select
                name="route_type"
                class="w-full text-sm rounded-md border-gray-300 dark:border-zinc-600 dark:bg-zinc-700 dark:text-zinc-100"
                data-testid="create-route-type-select"
              >
                <option value="general">General</option>
                <option value="project">Project</option>
                <option value="disambiguation">Disambiguation</option>
              </select>
            </div>
            <div>
              <label class="block text-xs font-medium text-gray-700 dark:text-zinc-300 mb-1">
                Source
              </label>
              <select
                name="source"
                class="w-full text-sm rounded-md border-gray-300 dark:border-zinc-600 dark:bg-zinc-700 dark:text-zinc-100"
                data-testid="create-route-source-select"
              >
                <%= for source <- Custyard.InboundRoute.sources() do %>
                  <option value={source}>{to_string(source)}</option>
                <% end %>
              </select>
            </div>
            <div>
              <label class="block text-xs font-medium text-gray-700 dark:text-zinc-300 mb-1">
                Project (optional)
              </label>
              <select
                name="project_id"
                class="w-full text-sm rounded-md border-gray-300 dark:border-zinc-600 dark:bg-zinc-700 dark:text-zinc-100"
                data-testid="create-route-project-select"
              >
                <option value="">None</option>
                <%= for project <- @available_projects do %>
                  <option value={project.id}>{project.title}</option>
                <% end %>
              </select>
            </div>
          </div>
          <div class="flex justify-end gap-2">
            <button
              type="button"
              phx-click="hide_create_route_form"
              class="px-3 py-1.5 text-sm text-gray-700 dark:text-zinc-300 hover:text-gray-900 dark:hover:text-zinc-100"
              data-testid="cancel-create-route-btn"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="px-3 py-1.5 text-sm font-medium text-white bg-indigo-600 hover:bg-indigo-700 rounded-md transition-colors"
              data-testid="submit-create-route-btn"
            >
              Create
            </button>
          </div>
        </form>
      </div>

      <%!-- Empty state --%>
      <div
        :if={@routes == []}
        class="text-center py-12"
        data-testid="org-routes-empty"
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
              d="M13.19 8.688a4.5 4.5 0 011.242 7.244l-4.5 4.5a4.5 4.5 0 01-6.364-6.364l1.757-1.757m9.07-9.07l4.5-4.5a4.5 4.5 0 016.364 6.364l-1.757 1.757"
            />
          </svg>
        </div>
        <p class="text-gray-600 dark:text-zinc-400 text-sm">No routes configured.</p>
      </div>

      <%!-- Route cards --%>
      <div
        :for={route <- @routes}
        class="p-4 bg-white dark:bg-zinc-800 rounded-lg border border-gray-200 dark:border-zinc-700"
        data-testid={"route-card-#{route.id}"}
      >
        <%!-- Route header: badges + delete --%>
        <div class="flex items-center justify-between mb-3">
          <div class="flex items-center gap-2">
            <.route_type_badge type={route.route_type} />
            <.source_badge source={route.source} />
            <span
              :if={route.project}
              class="text-xs text-gray-500 dark:text-zinc-400"
            >
              / {route.project.title}
            </span>
          </div>
          <div :if={@can_manage} class="flex items-center gap-2">
            <%= if @confirm_delete_route_id == route.id do %>
              <span class="text-xs text-red-600 dark:text-red-400 mr-1">Delete this route?</span>
              <button
                phx-click="delete_route"
                phx-value-id={route.id}
                class="text-xs px-2 py-1 text-white bg-red-600 hover:bg-red-700 rounded transition-colors"
                data-testid={"confirm-delete-route-#{route.id}"}
              >
                Yes, delete
              </button>
              <button
                phx-click="cancel_delete_route"
                class="text-xs px-2 py-1 text-gray-600 dark:text-zinc-400 hover:text-gray-900 dark:hover:text-zinc-100"
                data-testid={"cancel-delete-route-#{route.id}"}
              >
                Cancel
              </button>
            <% else %>
              <%!-- Disable delete for last general route --%>
              <% is_last = route.route_type == :general and @general_route_count <= 1 %>
              <button
                phx-click="confirm_delete_route"
                phx-value-id={route.id}
                disabled={is_last}
                class={[
                  "text-xs px-2 py-1 rounded transition-colors",
                  if(is_last,
                    do: "text-gray-400 dark:text-zinc-600 cursor-not-allowed",
                    else:
                      "text-red-600 dark:text-red-400 hover:text-red-800 dark:hover:text-red-300 hover:bg-red-50 dark:hover:bg-red-950"
                  )
                ]}
                title={if is_last, do: "Cannot delete the last general route", else: "Delete route"}
                data-testid={"delete-route-#{route.id}"}
              >
                Delete
              </button>
            <% end %>
          </div>
        </div>

        <%!-- Callback URL --%>
        <div class="mb-3">
          <div class="text-xs font-medium text-gray-500 dark:text-zinc-400 mb-1">
            Callback URL
          </div>
          <div class="flex items-center gap-2">
            <code
              class="flex-1 text-xs bg-gray-50 dark:bg-zinc-900 text-gray-700 dark:text-zinc-300 px-2 py-1.5 rounded border border-gray-200 dark:border-zinc-700 break-all"
              data-testid={"route-callback-url-#{route.id}"}
            >
              {InboundRoutes.callback_url(route)}
            </code>
            <button
              id={"copy-url-#{route.id}"}
              phx-hook="CopyToClipboard"
              data-clipboard-text={InboundRoutes.callback_url(route)}
              class="text-xs px-2 py-1.5 text-indigo-600 dark:text-indigo-400 hover:text-indigo-800 dark:hover:text-indigo-300 border border-indigo-200 dark:border-indigo-700 rounded hover:bg-indigo-50 dark:hover:bg-indigo-950 transition-colors whitespace-nowrap"
              data-testid={"copy-url-#{route.id}"}
            >
              Copy URL
            </button>
          </div>
        </div>

        <%!-- Webhook purpose toggles --%>
        <div>
          <div class="text-xs font-medium text-gray-500 dark:text-zinc-400 mb-1">
            Webhook Purposes
          </div>
          <div class="space-y-0.5">
            <%= for purpose <- Custyard.InboundRouteWebhook.purposes() do %>
              <% webhook = Enum.find(route.webhooks, fn w -> w.purpose == purpose end) %>
              <.webhook_purpose_toggle
                purpose={purpose}
                enabled={webhook != nil and webhook.enabled}
                route_id={route.id}
                disabled={not @can_manage}
              />
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp validate_param(value, allowed, field_name) do
    if value in allowed,
      do: :ok,
      else: {:error, "Invalid #{field_name}: #{value}"}
  end

  defp parse_id(value) do
    case Integer.parse(value) do
      {id, ""} -> {:ok, id}
      _ -> :error
    end
  end
end
