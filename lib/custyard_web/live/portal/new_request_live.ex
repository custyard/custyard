defmodule CustyardWeb.Portal.NewRequestLive do
  use CustyardWeb, :live_view

  alias Custyard.{Conversation, Message, Repo, Scoring}

  @impl true
  def mount(_params, _session, socket) do
    # :current_org, :portal_path, :portal_home_path set by PortalAuth on_mount

    {:ok,
     socket
     |> assign(:page_title, "New Request")
     |> assign(:form, to_form(%{"subject" => "", "body" => "", "urgency" => "normal"}))}
  end

  @allowed_urgencies ~w(normal elevated urgent)

  @impl true
  def handle_event("submit", %{"urgency" => urgency} = params, socket)
      when urgency in @allowed_urgencies do
    org = socket.assigns.current_org
    portal_path = socket.assigns.portal_path

    {:ok, conv} =
      %Conversation{}
      |> Conversation.changeset(%{
        organization_id: org.id,
        subject: params["subject"],
        state: :new,
        urgency: String.to_existing_atom(urgency),
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
    Phoenix.PubSub.broadcast(Custyard.PubSub, "conversations", {:conversation_created, conv.id})

    {:noreply, push_navigate(socket, to: "#{portal_path}/request/#{conv.id}")}
  end

  def handle_event("submit", _params, socket) do
    {:noreply, put_flash(socket, :error, "Invalid urgency value")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto py-8 px-4" data-testid="portal-new-request">
      <h1 class="text-2xl font-semibold text-gray-900 mb-6" data-testid="portal-new-request-heading">
        New Request
      </h1>

      <form phx-submit="submit" class="space-y-4" data-testid="portal-new-request-form">
        <div>
          <label
            class="block text-sm font-medium text-gray-700 mb-1"
            data-testid="portal-subject-label"
          >
            Subject
          </label>
          <input
            type="text"
            name="subject"
            required
            data-testid="portal-subject-input"
            class="w-full border-gray-300 rounded-lg focus:ring-indigo-500 focus:border-indigo-500"
            value={@form[:subject].value}
          />
        </div>

        <div>
          <label
            class="block text-sm font-medium text-gray-700 mb-1"
            data-testid="portal-urgency-label"
          >
            Urgency
          </label>
          <select
            name="urgency"
            class="w-full border-gray-300 rounded-lg focus:ring-indigo-500 focus:border-indigo-500"
            data-testid="portal-urgency-select"
          >
            <option value="normal">Normal</option>
            <option value="elevated">Elevated</option>
            <option value="urgent">Urgent</option>
          </select>
        </div>

        <div>
          <label class="block text-sm font-medium text-gray-700 mb-1" data-testid="portal-body-label">
            Description
          </label>
          <textarea
            name="body"
            rows="6"
            required
            data-testid="portal-body-textarea"
            class="w-full border-gray-300 rounded-lg resize-none focus:ring-indigo-500 focus:border-indigo-500"
          ><%= @form[:body].value %></textarea>
        </div>

        <div class="flex justify-end gap-3">
          <.link
            navigate={@portal_home_path}
            class="px-4 py-2 text-gray-700 hover:text-gray-900"
            data-testid="portal-cancel-link"
          >
            Cancel
          </.link>
          <button
            type="submit"
            class="bg-indigo-600 text-white px-4 py-2 rounded-lg hover:bg-indigo-700"
            data-testid="portal-submit"
          >
            Submit Request
          </button>
        </div>
      </form>
    </div>
    """
  end
end
