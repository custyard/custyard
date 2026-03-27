defmodule CustyardWeb.Portal.ConversationLive do
  use CustyardWeb, :live_view

  alias Custyard.{Conversations, Scoring}

  @impl true
  def mount(params, _session, socket) do
    # :current_org, :portal_path, :portal_home_path set by PortalAuth on_mount
    org = socket.assigns.current_org
    id = params["id"]

    case Conversations.get_conversation_for_organization(id, org.id) do
      {:error, _} ->
        {:ok,
         socket
         |> put_flash(:error, "Request not found")
         |> push_navigate(to: socket.assigns.portal_home_path)}

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
    org = socket.assigns.current_org

    # Re-verify the conversation still belongs to this organization
    case Conversations.get_conversation_for_organization(conv.id, org.id) do
      {:error, _} ->
        {:noreply,
         socket
         |> put_flash(:error, "This conversation is no longer accessible")
         |> push_navigate(to: socket.assigns.portal_home_path)}

      {:ok, conv} ->
        submit_reply(socket, conv, org, body)
    end
  end

  defp submit_reply(socket, conv, org, body) do
    if String.trim(body) != "" do
      sender_email = "portal@#{org.domain || "portal"}"

      case Conversations.create_message(%{
             conversation_id: conv.id,
             source: :portal,
             sender_email: sender_email,
             body: body,
             is_internal_note: false
           }) do
        {:ok, _message} ->
          # Update conversation timestamps and reactivate if needed, in a single write
          now = DateTime.utc_now() |> DateTime.truncate(:second)

          update_attrs =
            if conv.state in [:waiting, :dormant, :resolved] do
              %{last_customer_action_at: now, state: :active}
            else
              %{last_customer_action_at: now}
            end

          case Conversations.update_conversation(conv, update_attrs) do
            {:ok, updated_conv} ->
              Scoring.calculate_and_cache(conv.id)

              Phoenix.PubSub.broadcast(
                Custyard.PubSub,
                "conversations",
                {:conversation_updated, conv.id}
              )

              Phoenix.PubSub.broadcast(
                Custyard.PubSub,
                "conversations:org:#{conv.organization_id}",
                {:conversation_updated, conv.id}
              )

              Phoenix.PubSub.broadcast(
                Custyard.PubSub,
                "conversation:#{conv.id}",
                {:message_added, conv.id}
              )

              {:noreply,
               socket
               |> assign(:reply_form, to_form(%{"body" => ""}))
               |> assign(:conversation, updated_conv)
               |> load_messages()}

            {:error, _changeset} ->
              {:noreply, put_flash(socket, :error, "Failed to update conversation. Please try again.")}
          end

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to send reply. Please try again.")}
      end
    else
      {:noreply, put_flash(socket, :error, "Reply cannot be empty")}
    end
  end

  @impl true
  def handle_info({:message_added, _}, socket) do
    {:noreply, socket |> load_messages() |> load_tasks()}
  end

  # Catch-all for unexpected PubSub messages to prevent LiveView crashes
  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
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

      <div class="flex items-start justify-between gap-4 mb-6">
        <h1
          class="text-2xl font-semibold text-gray-900 dark:text-zinc-100"
          data-testid="portal-conversation-subject"
        >
          {@conversation.subject}
        </h1>
        <span
          class={"shrink-0 text-sm px-3 py-1 rounded-full #{state_color(@conversation.state)}"}
          data-testid="portal-conversation-state"
        >
          {state_label(@conversation.state)}
        </span>
      </div>

      <div class="space-y-4 mb-8" data-testid="portal-messages">
        <div
          :if={@messages == []}
          class="text-center py-8 text-gray-500 dark:text-zinc-400 bg-gray-50 dark:bg-zinc-800 rounded-lg"
          data-testid="portal-no-messages"
        >
          No messages yet. Start the conversation by sending a reply below.
        </div>
        <div
          :for={msg <- @messages}
          class={"p-4 rounded-lg #{message_style(msg)}"}
          data-testid={"portal-message-#{msg.source}"}
        >
          <div class={"flex justify-between text-sm mb-2 #{metadata_text_style(msg)}"}>
            <span data-testid="portal-message-sender">{sender_label(msg)}</span>
            <span data-testid="portal-message-time">{format_time(msg.inserted_at)}</span>
          </div>
          <div
            class={"whitespace-pre-wrap break-words #{body_text_style(msg)}"}
            data-testid="portal-message-body"
          >
            {msg.body}
          </div>
        </div>
      </div>

      <.tasks_section tasks={@tasks} />

      <form
        phx-submit="submit_reply"
        class="bg-white dark:bg-zinc-800 border dark:border-zinc-700 rounded-lg p-4"
        data-testid="portal-reply-form"
      >
        <textarea
          name="body"
          id="portal-reply-textarea"
          rows="4"
          aria-label="Reply to conversation"
          class="w-full border-gray-300 dark:border-zinc-600 dark:bg-zinc-700 dark:text-zinc-100 rounded-lg resize-none focus:ring-indigo-500 focus:border-indigo-500 phx-submit-loading:opacity-50 phx-submit-loading:cursor-not-allowed"
          placeholder="Write a reply..."
          phx-hook="ResetOnSubmit"
          data-testid="portal-reply-textarea"
        >{@reply_form[:body].value}</textarea>
        <div class="flex justify-end mt-3">
          <button
            type="submit"
            phx-disable-with="Sending..."
            class="bg-indigo-600 text-white px-4 py-2 rounded-lg hover:bg-indigo-700 phx-submit-loading:opacity-75 phx-submit-loading:cursor-not-allowed"
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
      <h2
        class="text-lg font-semibold text-gray-900 dark:text-zinc-100 mb-3"
        data-testid="portal-tasks-heading"
      >
        Tasks
      </h2>
      <div
        class="bg-white dark:bg-zinc-800 border dark:border-zinc-700 rounded-lg divide-y dark:divide-zinc-700"
        data-testid="portal-tasks-list"
      >
        <div :for={task <- @tasks} class="p-3 flex items-center gap-3" data-testid="portal-task-item">
          <.task_state_badge state={task.state} />
          <div class="flex-1">
            <div class="text-gray-900 dark:text-zinc-100" data-testid="portal-task-title">
              {task.title}
            </div>
            <div
              :if={task.due_at}
              class="text-sm text-gray-500 dark:text-zinc-400"
              data-testid="portal-task-due"
            >
              Due: {format_due_at(task.due_at)}
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp message_style(msg) do
    if msg.source == :operator do
      "bg-indigo-50 dark:bg-indigo-950 border-l-4 border-indigo-400 dark:border-indigo-600"
    else
      "bg-gray-50 dark:bg-zinc-800"
    end
  end

  defp metadata_text_style(msg) do
    if msg.source == :operator do
      # Higher contrast for operator messages: indigo-700 on indigo-50 background
      "text-indigo-700 dark:text-indigo-300"
    else
      "text-gray-500 dark:text-zinc-400"
    end
  end

  defp body_text_style(msg) do
    if msg.source == :operator do
      # Ensure good contrast for body text on indigo background
      "text-indigo-900 dark:text-indigo-100"
    else
      "text-gray-900 dark:text-zinc-100"
    end
  end

  defp sender_label(msg) do
    case msg.source do
      :operator -> "Support Team"
      _ -> msg.sender_email || "Customer"
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

  # Conversation state styling and labels for customers
  defp state_color(:new), do: "bg-blue-100 dark:bg-blue-950 text-blue-800 dark:text-blue-300"
  defp state_color(:active), do: "bg-green-100 dark:bg-green-950 text-green-800 dark:text-green-300"
  defp state_color(:waiting), do: "bg-yellow-100 dark:bg-yellow-950 text-yellow-800 dark:text-yellow-300"
  defp state_color(_), do: "bg-gray-100 dark:bg-zinc-700 text-gray-800 dark:text-zinc-200"

  # Customer-friendly state labels
  defp state_label(:new), do: "Open"
  defp state_label(:active), do: "In Progress"
  defp state_label(:waiting), do: "Awaiting Reply"
  defp state_label(:dormant), do: "On Hold"
  defp state_label(:resolved), do: "Closed"
  defp state_label(_), do: "Unknown"
end
