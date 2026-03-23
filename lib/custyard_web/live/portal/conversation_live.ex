defmodule CustyardWeb.Portal.ConversationLive do
  use CustyardWeb, :live_view

  alias Custyard.{Repo, Conversation, Conversations, Message, Scoring}

  @impl true
  def mount(%{"org_token" => token, "id" => id}, _session, socket) do
    org = Repo.get_by!(Custyard.Organization, token: token)

    case Conversations.get_conversation_for_organization(id, org.id) do
      {:error, _} ->
        {:ok, push_navigate(socket, to: ~p"/p/#{token}")}

      {:ok, conversation} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Custyard.PubSub, "conversation:#{id}")
        end

        {:ok,
         socket
         |> assign(:org, org)
         |> assign(:conversation, conversation)
         |> assign(:page_title, conversation.subject)
         |> assign(:reply_form, to_form(%{"body" => ""}))
         |> load_messages()}
    end
  end

  defp load_messages(socket) do
    conv = socket.assigns.conversation
    messages = Conversations.list_public_messages(conv.id)
    assign(socket, :messages, messages)
  end

  @impl true
  def handle_event("submit_reply", %{"body" => body}, socket) do
    conv = socket.assigns.conversation
    org = socket.assigns.org

    if String.trim(body) != "" do
      %Message{}
      |> Message.changeset(%{
        conversation_id: conv.id,
        source: :portal,
        sender_email: "portal@#{org.domain}",
        body: body,
        is_internal_note: false
      })
      |> Repo.insert!()

      # Update conversation timestamps and maybe reactivate
      conv
      |> Ecto.Changeset.change(last_customer_action_at: DateTime.utc_now())
      |> Repo.update!()

      if conv.state in [:waiting, :dormant, :resolved] do
        conv |> Conversation.state_changeset(:active) |> Repo.update!()
      end

      Scoring.calculate_and_cache(conv.id)
      Phoenix.PubSub.broadcast(Custyard.PubSub, "conversations", {:conversation_updated, conv.id})
      Phoenix.PubSub.broadcast(Custyard.PubSub, "conversation:#{conv.id}", {:message_added, conv.id})
    end

    {:noreply,
     socket
     |> assign(:reply_form, to_form(%{"body" => ""}))
     |> assign(:conversation, Repo.reload!(conv))
     |> load_messages()}
  end

  @impl true
  def handle_info({:message_added, _}, socket) do
    {:noreply, load_messages(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-8 px-4">
      <.link
        navigate={~p"/p/#{@org.token}"}
        class="text-indigo-600 hover:text-indigo-800 mb-4 inline-block"
      >
        &#8592; Back to requests
      </.link>

      <h1 class="text-2xl font-semibold text-gray-900 mb-6"><%= @conversation.subject %></h1>

      <div class="space-y-4 mb-8">
        <%= for msg <- @messages do %>
          <div class={"p-4 rounded-lg #{message_style(msg)}"}>
            <div class="flex justify-between text-sm text-gray-500 mb-2">
              <span><%= msg.sender_email %></span>
              <span><%= format_time(msg.inserted_at) %></span>
            </div>
            <div class="text-gray-900 whitespace-pre-wrap"><%= msg.body %></div>
          </div>
        <% end %>
      </div>

      <form phx-submit="submit_reply" class="bg-white border rounded-lg p-4">
        <textarea
          name="body"
          rows="4"
          class="w-full border-gray-300 rounded-lg resize-none focus:ring-indigo-500 focus:border-indigo-500"
          placeholder="Write a reply..."
        ><%= @reply_form[:body].value %></textarea>
        <div class="flex justify-end mt-3">
          <button
            type="submit"
            class="bg-indigo-600 text-white px-4 py-2 rounded-lg hover:bg-indigo-700"
          >
            Send Reply
          </button>
        </div>
      </form>
    </div>
    """
  end

  defp message_style(msg) do
    if msg.source == :operator do
      "bg-indigo-50 border-l-4 border-indigo-400"
    else
      "bg-gray-50"
    end
  end

  defp format_time(datetime) do
    Calendar.strftime(datetime, "%b %d, %H:%M")
  end
end
