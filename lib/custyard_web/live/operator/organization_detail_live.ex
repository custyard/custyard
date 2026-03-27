defmodule CustyardWeb.Operator.OrganizationDetailLive do
  @moduledoc """
  Organization detail view showing conversations, contacts, and organization info.
  """
  use CustyardWeb, :live_view

  import CustyardWeb.OperatorComponents

  alias Custyard.{Conversations, Organizations, Projects}

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
          |> load_tab_data(org, "conversations")

        {:ok, socket, layout: {CustyardWeb.Layouts, :operator}}
    end
  end

  @impl true
  def handle_params(%{"tab" => tab}, _uri, socket) when tab in ~w(conversations contacts projects) do
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
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 19l-7-7 7-7" />
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
                <span class="text-indigo-600 dark:text-indigo-400" data-testid="org-detail-custom-domain">
                  {@organization.custom_domain}
                </span>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Tabs --%>
        <div class="mt-4 flex gap-4 border-b border-gray-200 dark:border-zinc-700 -mb-px">
          <.tab_link tab="conversations" current={@tab} patch={~p"/operator/organizations/#{@organization.id}?tab=conversations"}>
            Conversations
          </.tab_link>
          <.tab_link tab="contacts" current={@tab} patch={~p"/operator/organizations/#{@organization.id}?tab=contacts"}>
            Contacts
          </.tab_link>
          <.tab_link tab="projects" current={@tab} patch={~p"/operator/organizations/#{@organization.id}?tab=projects"}>
            Projects
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
          else: "border-transparent text-gray-600 dark:text-zinc-400 hover:text-gray-900 dark:hover:text-zinc-200 hover:border-gray-300 dark:hover:border-zinc-600"
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
              {project.name}
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
end
