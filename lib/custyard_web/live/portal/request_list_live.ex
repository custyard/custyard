defmodule CustyardWeb.Portal.RequestListLive do
  use CustyardWeb, :live_view

  alias Custyard.Conversations
  alias CustyardWeb.Portal.Helpers

  @impl true
  def mount(params, _session, socket) do
    org = Helpers.get_organization(params, socket)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Custyard.PubSub, "conversations")
    end

    {:ok,
     socket
     |> assign(:org, org)
     |> Helpers.assign_portal_path()
     |> assign(:current_contact, nil)
     |> assign(:admin_mode, false)
     |> assign(:page_title, "My Requests")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # Allow simulating a contact via ?as=<contact_id> for testing
    # Only enabled in dev/test environments via config
    {contact, admin_mode} = maybe_impersonate_contact(params, socket.assigns.org.id)

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

  def handle_info({:conversation_created, _id}, socket) do
    {:noreply, load_conversations(socket)}
  end

  defp load_conversations(socket) do
    org = socket.assigns.org
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
          <h1 class="text-2xl font-semibold text-gray-900" data-testid="portal-request-list-heading">
            {if @admin_mode, do: "All Organization Requests", else: "My Requests"}
          </h1>
          <p :if={@current_contact} class="text-sm text-gray-500 mt-1" data-testid="portal-viewing-as">
            Viewing as: {@current_contact.name || @current_contact.email}
          </p>
        </div>
        <div class="flex items-center gap-4">
          <div :if={@current_contact && @current_contact.is_admin} class="flex items-center gap-2">
            <label class="text-sm text-gray-600">Admin view</label>
            <button
              type="button"
              phx-click="toggle_admin_mode"
              data-testid="portal-admin-toggle"
              class={[
                "relative inline-flex h-6 w-11 flex-shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200 ease-in-out focus:outline-none focus:ring-2 focus:ring-indigo-600 focus:ring-offset-2",
                if(@admin_mode, do: "bg-indigo-600", else: "bg-gray-200")
              ]}
              role="switch"
              aria-checked={to_string(@admin_mode)}
            >
              <span class={[
                "pointer-events-none inline-block h-5 w-5 transform rounded-full bg-white shadow ring-0 transition duration-200 ease-in-out",
                if(@admin_mode, do: "translate-x-5", else: "translate-x-0")
              ]}>
              </span>
            </button>
          </div>
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
          <div class="bg-white border rounded-lg p-4 hover:border-indigo-300 transition">
            <div class="flex justify-between items-start">
              <div>
                <h3 class="font-medium text-gray-900" data-testid="portal-request-subject">
                  {conv.subject}
                </h3>
                <p class="text-sm text-gray-500 mt-1" data-testid="portal-request-meta">
                  {if conv.contact, do: conv.contact.name || conv.contact.email, else: "Unknown"} · {relative_time(
                    conv.inserted_at
                  )}
                </p>
              </div>
              <span
                class={"px-2 py-1 text-xs rounded-full #{state_color(conv.state)}"}
                data-testid="portal-state-badge"
              >
                {conv.state}
              </span>
            </div>
          </div>
        </.link>

        <div
          :if={@conversations == []}
          class="text-center py-12 text-gray-500"
          data-testid="portal-empty-state"
        >
          No open requests. Create one to get started.
        </div>
      </div>
    </div>
    """
  end

  defp state_color(:new), do: "bg-blue-100 text-blue-800"
  defp state_color(:active), do: "bg-green-100 text-green-800"
  defp state_color(:waiting), do: "bg-yellow-100 text-yellow-800"
  defp state_color(_), do: "bg-gray-100 text-gray-800"

  defp relative_time(datetime) do
    diff = DateTime.diff(DateTime.utc_now(), datetime, :hour)

    cond do
      diff < 1 -> "just now"
      diff < 24 -> "#{diff}h ago"
      true -> "#{div(diff, 24)}d ago"
    end
  end

  # Contact impersonation via ?as= param - only in dev/test
  if Application.compile_env(:custyard, :allow_contact_impersonation, false) do
    defp maybe_impersonate_contact(%{"as" => nil}, _org_id), do: {nil, false}

    defp maybe_impersonate_contact(%{} = params, _org_id) when not is_map_key(params, "as"),
      do: {nil, false}

    defp maybe_impersonate_contact(%{"as" => contact_id} = params, org_id) do
      alias Custyard.{Contact, Repo}
      contact = Repo.get_by(Contact, id: contact_id, organization_id: org_id)
      # Only admin contacts can use admin mode
      admin_mode = contact && contact.is_admin && params["admin"] == "true"
      {contact, admin_mode}
    end
  else
    defp maybe_impersonate_contact(_params, _org_id), do: {nil, false}
  end
end
