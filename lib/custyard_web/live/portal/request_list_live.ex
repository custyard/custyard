defmodule CustyardWeb.Portal.RequestListLive do
  use CustyardWeb, :live_view

  alias Custyard.Conversations

  @impl true
  def mount(_params, _session, socket) do
    # :current_org, :portal_path, :portal_home_path set by PortalAuth on_mount

    if connected?(socket) do
      org = socket.assigns.current_org
      Phoenix.PubSub.subscribe(Custyard.PubSub, "conversations:org:#{org.id}")
    end

    {:ok,
     socket
     |> assign(:current_contact, nil)
     |> assign(:admin_mode, false)
     |> assign(:page_title, "My Requests")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Allow simulating a contact via ?as=<contact_id> for testing
    # Only enabled in dev/test environments via config
    {contact, admin_mode} = maybe_impersonate_contact(params, socket.assigns.current_org.id)

    {:noreply,
     socket
     |> assign(:current_contact, contact)
     |> assign(:admin_mode, admin_mode)
     |> load_conversations()}
  end

  @impl true
  def handle_event("toggle_admin_mode", _params, socket) do
    contact = socket.assigns.current_contact

    # Only admin contacts can toggle admin mode
    if contact && contact.is_admin do
      new_mode = !socket.assigns.admin_mode

      {:noreply,
       socket
       |> assign(:admin_mode, new_mode)
       |> load_conversations()}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:conversation_updated, _id}, socket) do
    {:noreply, load_conversations(socket)}
  end

  @impl true
  def handle_info({:conversation_created, _id}, socket) do
    {:noreply, load_conversations(socket)}
  end

  # Catch-all for unexpected messages to prevent FunctionClauseError crashes
  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp load_conversations(socket) do
    org = socket.assigns.current_org
    contact = socket.assigns.current_contact
    admin_mode = socket.assigns.admin_mode

    opts =
      cond do
        # No contact - show all org conversations (legacy behavior)
        is_nil(contact) ->
          []

        # Admin mode enabled - show all org conversations
        admin_mode ->
          []

        # Regular contact - show only their conversations
        true ->
          [contact_id: contact.id]
      end

    conversations = Conversations.list_for_organization(org.id, opts)
    assign(socket, :conversations, conversations)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-8 px-4" data-testid="portal-request-list">
      <div class="flex justify-between items-center mb-6">
        <div>
          <h1
            class="text-2xl font-semibold text-gray-900 dark:text-zinc-100"
            data-testid="portal-request-list-heading"
          >
            {if @admin_mode, do: "All Organization Requests", else: "My Requests"}
          </h1>
          <p
            :if={@current_contact}
            class="text-sm text-gray-500 dark:text-zinc-400 mt-1"
            data-testid="portal-viewing-as"
          >
            Viewing as: {@current_contact.name || @current_contact.email}
          </p>
        </div>
        <div class="flex items-center gap-4">
          <div :if={@current_contact && @current_contact.is_admin} class="flex items-center gap-2">
            <label id="admin-view-label" class="text-sm text-gray-600 dark:text-zinc-400">
              Admin view
            </label>
            <button
              type="button"
              phx-click="toggle_admin_mode"
              data-testid="portal-admin-toggle"
              class={[
                "relative inline-flex h-6 w-11 shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none focus:ring-2 focus:ring-indigo-600 focus:ring-offset-2",
                if(@admin_mode, do: "bg-indigo-600", else: "bg-gray-200 dark:bg-zinc-700")
              ]}
              role="switch"
              aria-checked={to_string(@admin_mode)}
              aria-labelledby="admin-view-label"
            >
              <span class={[
                "pointer-events-none inline-block h-5 w-5 rounded-full bg-white shadow ring-0 transition-transform duration-200 ease-in-out",
                if(@admin_mode, do: "translate-x-5", else: "translate-x-0")
              ]}></span>
            </button>
          </div>
          <.link
            navigate={"#{@portal_path}/projects"}
            class="text-indigo-600 dark:text-indigo-400 px-4 py-2 rounded-lg hover:bg-indigo-50 dark:hover:bg-indigo-900/30"
            data-testid="portal-projects-link"
          >
            View Projects
          </.link>
          <.link
            navigate={"#{@portal_path}/new"}
            class="bg-indigo-600 text-white px-4 py-2 rounded-lg hover:bg-indigo-700"
            data-testid="portal-new-request-link"
          >
            + New Request
          </.link>
        </div>
      </div>

      <div class="space-y-4">
        <.link
          :for={conv <- @conversations}
          navigate={"#{@portal_path}/request/#{conv.id}"}
          class="block"
          data-testid={"portal-request-item-#{conv.id}"}
        >
          <div class="bg-white dark:bg-zinc-800 border dark:border-zinc-700 rounded-lg p-4 hover:border-indigo-300 transition-colors">
            <div class="flex justify-between items-start">
              <div>
                <h3
                  class="font-medium text-gray-900 dark:text-zinc-100"
                  data-testid="portal-request-subject"
                >
                  {conv.subject}
                </h3>
                <p
                  class="text-sm text-gray-500 dark:text-zinc-400 mt-1"
                  data-testid="portal-request-meta"
                >
                  {if conv.contact, do: conv.contact.name || conv.contact.email, else: "Unknown"} · {relative_time(
                    conv.inserted_at
                  )}
                </p>
              </div>
              <span
                class={"px-2 py-1 text-xs rounded-full #{state_color(conv.state)}"}
                data-testid="portal-state-badge"
              >
                {state_label(conv.state)}
              </span>
            </div>
          </div>
        </.link>

        <div
          :if={@conversations == []}
          class="text-center py-12"
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
                d="M8.625 12a.375.375 0 11-.75 0 .375.375 0 01.75 0zm0 0H8.25m4.125 0a.375.375 0 11-.75 0 .375.375 0 01.75 0zm0 0H12m4.125 0a.375.375 0 11-.75 0 .375.375 0 01.75 0zm0 0h-.375M21 12c0 4.556-4.03 8.25-9 8.25a9.764 9.764 0 01-2.555-.337A5.972 5.972 0 015.41 20.97a5.969 5.969 0 01-.474-.065 4.48 4.48 0 00.978-2.025c.09-.457-.133-.901-.467-1.226C3.93 16.178 3 14.189 3 12c0-4.556 4.03-8.25 9-8.25s9 3.694 9 8.25z"
              />
            </svg>
          </div>
          <p class="text-gray-600 dark:text-zinc-400 text-sm">
            No open requests. Create one to get started.
          </p>
        </div>
      </div>
    </div>
    """
  end

  defp state_color(:new), do: "bg-blue-100 dark:bg-blue-950 text-blue-800 dark:text-blue-300"

  defp state_color(:active),
    do: "bg-green-100 dark:bg-green-950 text-green-800 dark:text-green-300"

  defp state_color(:waiting),
    do: "bg-yellow-100 dark:bg-yellow-950 text-yellow-800 dark:text-yellow-300"

  defp state_color(_), do: "bg-gray-100 dark:bg-zinc-700 text-gray-800 dark:text-zinc-200"

  # Customer-friendly state labels
  defp state_label(:new), do: "Open"
  defp state_label(:active), do: "In Progress"
  defp state_label(:waiting), do: "Awaiting Reply"
  defp state_label(:dormant), do: "On Hold"
  defp state_label(:resolved), do: "Closed"
  defp state_label(_), do: "Unknown"

  defp relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :hour)

    cond do
      diff < 1 -> "just now"
      diff < 24 -> "#{diff}h ago"
      true -> "#{div(diff, 24)}d ago"
    end
  end

  # Contact impersonation via ?as= param - only when explicitly enabled at runtime.
  # This is a runtime check (not compile-time) so it can be disabled even if the
  # binary was built with the wrong config.
  defp maybe_impersonate_contact(params, org_id) do
    if impersonation_enabled?() do
      do_impersonate_contact(params, org_id)
    else
      {nil, false}
    end
  end

  defp impersonation_enabled? do
    Application.get_env(:custyard, :allow_contact_impersonation, false) == true
  end

  defp do_impersonate_contact(%{"as" => nil}, _org_id), do: {nil, false}

  defp do_impersonate_contact(%{} = params, _org_id) when not is_map_key(params, "as"),
    do: {nil, false}

  defp do_impersonate_contact(%{"as" => contact_id} = params, org_id) do
    alias Custyard.{Contact, Repo}
    contact = Repo.get_by(Contact, id: contact_id, organization_id: org_id)
    # Only admin contacts can use admin mode
    admin_mode = contact && contact.is_admin && params["admin"] == "true"
    {contact, admin_mode}
  end
end
