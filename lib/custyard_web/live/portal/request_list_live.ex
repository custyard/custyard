defmodule CustyardWeb.Portal.RequestListLive do
  use CustyardWeb, :live_view

  alias Custyard.{Repo, Conversation}
  import Ecto.Query

  @impl true
  def mount(%{"org_token" => token}, _session, socket) do
    org = Repo.get_by!(Custyard.Organization, token: token)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Custyard.PubSub, "conversations")
    end

    {:ok,
     socket
     |> assign(:org, org)
     |> assign(:page_title, "My Requests")
     |> load_conversations()}
  end

  @impl true
  def handle_info({:conversation_updated, _id}, socket) do
    {:noreply, load_conversations(socket)}
  end

  defp load_conversations(socket) do
    org = socket.assigns.org

    conversations =
      from(c in Conversation,
        where: c.organization_id == ^org.id,
        where: c.state != :resolved,
        order_by: [desc: c.inserted_at],
        preload: [:contact]
      )
      |> Repo.all()

    assign(socket, :conversations, conversations)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-8 px-4">
      <div class="flex justify-between items-center mb-6">
        <h1 class="text-2xl font-semibold text-gray-900">My Requests</h1>
        <.link
          navigate={~p"/p/#{@org.token}/new"}
          class="bg-indigo-600 text-white px-4 py-2 rounded-lg hover:bg-indigo-700"
        >
          + New Request
        </.link>
      </div>

      <div class="space-y-4">
        <%= for conv <- @conversations do %>
          <.link navigate={~p"/p/#{@org.token}/request/#{conv.id}"} class="block">
            <div class="bg-white border rounded-lg p-4 hover:border-indigo-300 transition">
              <div class="flex justify-between items-start">
                <div>
                  <h3 class="font-medium text-gray-900"><%= conv.subject %></h3>
                  <p class="text-sm text-gray-500 mt-1">
                    <%= if conv.contact, do: conv.contact.name || conv.contact.email, else: "Unknown" %>
                    · <%= relative_time(conv.inserted_at) %>
                  </p>
                </div>
                <span class={"px-2 py-1 text-xs rounded-full #{state_color(conv.state)}"}>
                  <%= conv.state %>
                </span>
              </div>
            </div>
          </.link>
        <% end %>

        <%= if @conversations == [] do %>
          <div class="text-center py-12 text-gray-500">
            No open requests. Create one to get started.
          </div>
        <% end %>
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
end
