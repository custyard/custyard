defmodule CustyardWeb.Portal.ConversationLive do
  use CustyardWeb, :live_view

  alias Custyard.{Conversations, Scoring}
  alias CustyardWeb.Portal.Helpers

  @impl true
  def mount(params, _session, socket) do
    org = Helpers.get_organization(params, socket)
    id = params["id"]

    socket =
      socket
      |> assign(:org, org)
      |> Helpers.assign_portal_path()

    case Conversations.get_conversation_for_organization(id, org.id) do
      {:error, _} ->
        {:ok, push_navigate(socket, to: socket.assigns.portal_home_path)}

      {:ok, conversation} ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Custyard.PubSub, "conversation:#{id}")
        end

        {:ok,
         socket
         |> assign(:conversation, conversation)
         |> assign(:page_title, conversation.subject)
         |> assign(:reply_form, to_form(%{"body" => ""}))
         |> load_messages()
         |> load_tasks()}
    end
  end

  defp load_messages(socket) do
    conv = socket.assigns.conversation
    messages = Conversations.list_public_messages(conv.id)
    assign(socket, :messages, messages)
  end

  defp load_tasks(socket) do
    conv = socket.assigns.conversation
    tasks = Conversations.list_portal_visible_tasks(conv.id)
    assign(socket, :tasks, tasks)
  end

  @impl true
  def handle_event("submit_reply", %{"body" => body}, socket) do
    conv = socket.assigns.conversation
    org = socket.assigns.org

    if String.trim(body) != "" do
      Conversations.create_message!(%{
        conversation_id: conv.id,
        source: :portal,
        sender_email: "portal@#{org.domain}",
        body: body,
        is_internal_note: false
      })

      # Update conversation timestamps and maybe reactivate
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, _} = Conversations.update_conversation(conv, last_customer_action_at: now)

      if conv.state in [:waiting, :dormant, :resolved] do
        {:ok, _} = Conversations.update_state(conv, :active)
      end

      Scoring.calculate_and_cache(conv.id)
      Phoenix.PubSub.broadcast(Custyard.PubSub, "conversations", {:conversation_updated, conv.id})

      Phoenix.PubSub.broadcast(
        Custyard.PubSub,
        "conversation:#{conv.id}",
        {:message_added, conv.id}
      )
    end

    {:noreply,
     socket
     |> assign(:reply_form, to_form(%{"body" => ""}))
     |> assign(:conversation, Conversations.reload!(conv))
     |> load_messages()}
  end

  @impl true
  def handle_info({:message_added, _}, socket) do
    {:noreply, load_messages(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-8 px-4" data-testid="portal-conversation">
      <.link
        navigate={@portal_home_path}
        class="text-indigo-600 hover:text-indigo-800 mb-4 inline-block"
        data-testid="portal-back-link"
      >
        &#8592; Back to requests
      </.link>

      <h1 class="text-2xl font-semibold text-gray-900 mb-6" data-testid="portal-conversation-subject">
        {@conversation.subject}
      </h1>

      <div class="space-y-4 mb-8" data-testid="portal-messages">
        <%= for msg <- @messages do %>
          <div
            class={"p-4 rounded-lg #{message_style(msg)}"}
            data-testid={"portal-message-#{msg.source}"}
          >
            <div class="flex justify-between text-sm text-gray-500 mb-2">
              <span>{msg.sender_email}</span>
              <span>{format_time(msg.inserted_at)}</span>
            </div>
            <div class="text-gray-900 whitespace-pre-wrap">{msg.body}</div>
          </div>
        <% end %>
      </div>

      <.tasks_section tasks={@tasks} />

      <form
        phx-submit="submit_reply"
        class="bg-white border rounded-lg p-4"
        data-testid="portal-reply-form"
      >
        <textarea
          name="body"
          rows="4"
          class="w-full border-gray-300 rounded-lg resize-none focus:ring-indigo-500 focus:border-indigo-500"
          placeholder="Write a reply..."
          data-testid="portal-reply-textarea"
        >{@reply_form[:body].value}</textarea>
        <div class="flex justify-end mt-3">
          <button
            type="submit"
            class="bg-indigo-600 text-white px-4 py-2 rounded-lg hover:bg-indigo-700"
            data-testid="portal-reply-submit"
          >
            Send Reply
          </button>
        </div>
      </form>
    </div>
    """
  end

  attr :tasks, :list, required: true

  defp tasks_section(assigns) do
    ~H"""
    <div :if={@tasks != []} class="mb-8" data-testid="portal-tasks-section">
      <h2 class="text-lg font-semibold text-gray-900 mb-3">Tasks</h2>
      <div class="bg-white border rounded-lg divide-y" data-testid="portal-tasks-list">
        <%= for task <- @tasks do %>
          <div class="p-3 flex items-center gap-3" data-testid="portal-task-item">
            <.task_state_badge state={task.state} />
            <div class="flex-1">
              <div class="text-gray-900" data-testid="portal-task-title">{task.title}</div>
              <div :if={task.due_at} class="text-sm text-gray-500">
                Due: {format_due_at(task.due_at)}
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :state, :atom, required: true

  defp task_state_badge(assigns) do
    {bg_color, text_color, label} =
      case assigns.state do
        :done -> {"bg-green-100", "text-green-800", "Done"}
        :in_progress -> {"bg-blue-100", "text-blue-800", "In Progress"}
        :open -> {"bg-gray-100", "text-gray-600", "Open"}
        _ -> {"bg-gray-100", "text-gray-600", "Open"}
      end

    assigns =
      assigns
      |> assign(:bg_color, bg_color)
      |> assign(:text_color, text_color)
      |> assign(:label, label)

    ~H"""
    <span class={"text-xs px-2 py-1 rounded #{@bg_color} #{@text_color}"}>
      {@label}
    </span>
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

  defp format_due_at(datetime) do
    now = DateTime.utc_now()
    diff_days = Date.diff(DateTime.to_date(datetime), DateTime.to_date(now))

    cond do
      diff_days < 0 -> "overdue"
      diff_days == 0 -> "today"
      diff_days == 1 -> "tomorrow"
      diff_days < 7 -> Calendar.strftime(datetime, "%A")
      true -> Calendar.strftime(datetime, "%b %d")
    end
  end
end
