defmodule CustyardWeb.Portal.NewRequestLive do
  use CustyardWeb, :live_view

  alias Custyard.{Repo, Conversation, Message, Scoring}

  @impl true
  def mount(%{"org_token" => token}, _session, socket) do
    org = Repo.get_by!(Custyard.Organization, token: token)

    {:ok,
     socket
     |> assign(:org, org)
     |> assign(:page_title, "New Request")
     |> assign(:form, to_form(%{"subject" => "", "body" => "", "urgency" => "normal"}))}
  end

  @impl true
  def handle_event("submit", params, socket) do
    org = socket.assigns.org

    {:ok, conv} =
      %Conversation{}
      |> Conversation.changeset(%{
        organization_id: org.id,
        subject: params["subject"],
        state: :new,
        urgency: String.to_existing_atom(params["urgency"]),
        last_customer_action_at: DateTime.utc_now()
      })
      |> Repo.insert()

    %Message{}
    |> Message.changeset(%{
      conversation_id: conv.id,
      source: :portal,
      sender_email: "portal@#{org.domain}",
      body: params["body"],
      is_internal_note: false
    })
    |> Repo.insert!()

    Scoring.calculate_and_cache(conv.id)
    Phoenix.PubSub.broadcast(Custyard.PubSub, "conversations", {:conversation_updated, conv.id})

    {:noreply, push_navigate(socket, to: ~p"/p/#{org.token}/request/#{conv.id}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto py-8 px-4">
      <h1 class="text-2xl font-semibold text-gray-900 mb-6">New Request</h1>

      <form phx-submit="submit" class="space-y-4">
        <div>
          <label class="block text-sm font-medium text-gray-700 mb-1">Subject</label>
          <input
            type="text"
            name="subject"
            required
            class="w-full border-gray-300 rounded-lg focus:ring-indigo-500 focus:border-indigo-500"
            value={@form[:subject].value}
          />
        </div>

        <div>
          <label class="block text-sm font-medium text-gray-700 mb-1">Urgency</label>
          <select
            name="urgency"
            class="w-full border-gray-300 rounded-lg focus:ring-indigo-500 focus:border-indigo-500"
          >
            <option value="normal">Normal</option>
            <option value="elevated">Elevated</option>
            <option value="urgent">Urgent</option>
          </select>
        </div>

        <div>
          <label class="block text-sm font-medium text-gray-700 mb-1">Description</label>
          <textarea
            name="body"
            rows="6"
            required
            class="w-full border-gray-300 rounded-lg resize-none focus:ring-indigo-500 focus:border-indigo-500"
          ><%= @form[:body].value %></textarea>
        </div>

        <div class="flex justify-end gap-3">
          <.link
            navigate={~p"/p/#{@org.token}"}
            class="px-4 py-2 text-gray-700 hover:text-gray-900"
          >
            Cancel
          </.link>
          <button
            type="submit"
            class="bg-indigo-600 text-white px-4 py-2 rounded-lg hover:bg-indigo-700"
          >
            Submit Request
          </button>
        </div>
      </form>
    </div>
    """
  end
end
