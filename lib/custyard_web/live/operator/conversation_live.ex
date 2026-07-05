defmodule CustyardWeb.Operator.ConversationLive do
  @moduledoc """
  Operator view for a single conversation with reply, state management, and task tools.

  ## Authorization Model

  Access is controlled by `Custyard.Authorization`:
  - super_admin can access any conversation
  - admin/agent can access conversations in their organization, plus unlinked
    (nil-org) conversations — mirroring `Custyard.Authorization.can_access_conversation?/2`
  - Only admin+ can change conversation state (active/waiting/resolved)
  """
  use CustyardWeb, :live_view

  import CustyardWeb.OperatorComponents

  alias Custyard.{Authorization, Conversation, Conversations, Message, Scoring}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case load_conversation(id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Conversation not found")
         |> redirect(to: ~p"/operator")}

      conversation ->
        if Authorization.can_access_conversation?(socket.assigns.current_operator, conversation) do
          mount_conversation(socket, id, conversation)
        else
          {:ok,
           socket
           |> put_flash(:error, "You do not have access to this conversation")
           |> redirect(to: ~p"/operator")}
        end
    end
  end

  defp mount_conversation(socket, id, conversation) do
    if connected?(socket) do
      # Subscribe to org-scoped topic instead of global "conversations" to reduce
      # unnecessary PubSub traffic. Unlinked (nil-org) conversations have no org
      # topic, and their state changes are only published on the global topic
      # (the "conversation:{id}" topic carries message events, not state changes),
      # so fall back to the global topic; handle_info filters by conversation id.
      if conversation.organization_id do
        Phoenix.PubSub.subscribe(
          Custyard.PubSub,
          "conversations:org:#{conversation.organization_id}"
        )
      else
        Phoenix.PubSub.subscribe(Custyard.PubSub, "conversations")
      end

      Phoenix.PubSub.subscribe(Custyard.PubSub, "conversation:#{id}")
    end

    # Atomically transition new->active when operator views (race-condition safe).
    # Uses conditional UPDATE to prevent conflicts when multiple operators open simultaneously.
    conversation =
      if conversation.state == :new do
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        case Conversations.transition_state(conversation, :new, :active,
               last_operator_action_at: now
             ) do
          {:ok, %Conversation{}} ->
            # Transition succeeded - this operator was first
            Scoring.calculate_and_cache(conversation.id)

            # Broadcast the state change
            Phoenix.PubSub.broadcast(
              Custyard.PubSub,
              "conversations",
              {:conversation_updated, conversation.id}
            )

            Conversations.broadcast_to_org(
              conversation.organization_id,
              {:conversation_updated, conversation.id}
            )

            # Reload with all associations (messages, etc.)
            load_conversation(id)

          {:ok, :already_transitioned} ->
            # Another operator already transitioned it - reload fresh data
            load_conversation(id)
        end
      else
        conversation
      end

    breakdown = Scoring.breakdown(conversation)
    neglect_status = Scoring.neglect_status(conversation)
    other_conversations = fetch_other_org_conversations(conversation)

    socket =
      socket
      |> assign(:page_title, truncate_subject(conversation.subject))
      |> assign(:conversation, conversation)
      |> assign(:breakdown, breakdown)
      |> assign(:neglect_status, neglect_status)
      |> assign(:other_conversations, other_conversations)
      |> assign(:reply_text, "")
      |> assign(:note_text, "")
      |> assign(:new_task_title, "")
      |> assign(:new_task_due_at, "")
      |> assign(:new_task_portal_visible, true)
      |> assign(:show_task_form, false)
      |> assign(:editing_task_id, nil)
      |> assign(:edit_task_title, "")
      |> assign(:edit_task_due_at, "")
      |> assign(:edit_task_portal_visible, true)
      |> assign(:show_sidebar, false)

    {:ok, socket, layout: {CustyardWeb.Layouts, :operator}}
  end

  @impl true
  def handle_event("send_reply", %{"body" => body}, socket) when byte_size(body) > 0 do
    conversation = socket.assigns.conversation
    operator = socket.assigns.current_operator

    case Conversations.send_reply(conversation, body, operator_email: operator.email) do
      {:ok, _message} ->
        socket = socket |> assign(:reply_text, "") |> reload_conversation()

        socket =
          if deliverable_recipient?(conversation) do
            socket
          else
            put_flash(
              socket,
              :error,
              "Reply saved, but the contact has no email address so it cannot be delivered"
            )
          end

        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to send reply")}
    end
  end

  def handle_event("send_reply", _params, socket), do: {:noreply, socket}

  def handle_event("add_note", %{"body" => body}, socket) when byte_size(body) > 0 do
    conversation = socket.assigns.conversation

    case Conversations.create_message(%{
           source: :operator,
           body: body,
           is_internal_note: true,
           conversation_id: conversation.id
         }) do
      {:ok, _message} ->
        Phoenix.PubSub.broadcast(
          Custyard.PubSub,
          "conversation:#{conversation.id}",
          {:message_added, conversation.id}
        )

        {:noreply, socket |> assign(:note_text, "") |> reload_conversation()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to add note")}
    end
  end

  def handle_event("add_note", _params, socket), do: {:noreply, socket}

  def handle_event("update_reply", %{"body" => body}, socket) do
    {:noreply, assign(socket, :reply_text, body)}
  end

  def handle_event("update_note", %{"body" => body}, socket) do
    {:noreply, assign(socket, :note_text, body)}
  end

  def handle_event("set_state", %{"state" => state}, socket)
      when state in ~w(active waiting resolved) do
    if Authorization.can_set_conversation_state?(socket.assigns.current_operator) do
      conversation = socket.assigns.conversation
      new_state = String.to_existing_atom(state)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      case Conversations.update_conversation(conversation, %{
             state: new_state,
             last_operator_action_at: now
           }) do
        {:ok, _} ->
          Scoring.calculate_and_cache(conversation.id)

          Phoenix.PubSub.broadcast(
            Custyard.PubSub,
            "conversations",
            {:conversation_updated, conversation.id}
          )

          Conversations.broadcast_to_org(
            conversation.organization_id,
            {:conversation_updated, conversation.id}
          )

          {:noreply, reload_conversation(socket)}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to update state")}
      end
    else
      {:noreply, put_flash(socket, :error, "Only admins can change conversation state")}
    end
  end

  def handle_event("set_state", %{"state" => _state}, socket) do
    # Invalid state value - silently ignore (could also flash an error)
    {:noreply, socket}
  end

  def handle_event("toggle_task_form", _params, socket) do
    {:noreply, assign(socket, :show_task_form, !socket.assigns.show_task_form)}
  end

  def handle_event("toggle_sidebar", _params, socket) do
    {:noreply, assign(socket, :show_sidebar, !socket.assigns.show_sidebar)}
  end

  def handle_event("update_new_task", params, socket) do
    socket =
      socket
      |> assign(:new_task_title, params["title"] || socket.assigns.new_task_title)
      |> assign(:new_task_due_at, params["due_at"] || socket.assigns.new_task_due_at)
      |> assign(:new_task_portal_visible, params["portal_visible"] == "true")

    {:noreply, socket}
  end

  def handle_event("add_task", params, socket) do
    title = params["title"] || ""

    if byte_size(title) > 0 do
      conversation = socket.assigns.conversation
      due_at = parse_due_at(params["due_at"])
      portal_visible = params["portal_visible"] == "true"

      case Conversations.create_task(%{
             title: title,
             due_at: due_at,
             portal_visible: portal_visible,
             conversation_id: conversation.id
           }) do
        {:ok, _task} ->
          {:noreply,
           socket
           |> assign(:new_task_title, "")
           |> assign(:new_task_due_at, "")
           |> assign(:new_task_portal_visible, true)
           |> assign(:show_task_form, false)
           |> put_flash(:info, "Task created")
           |> reload_conversation()}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to create task")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_task", %{"id" => id}, socket) do
    task = get_scoped_task!(socket, id)

    new_state =
      case task.state do
        :open -> :in_progress
        :in_progress -> :done
        :done -> :open
      end

    case Conversations.update_task_state(task, new_state) do
      {:ok, _} ->
        {:noreply, reload_conversation(socket)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update task")}
    end
  end

  def handle_event("edit_task", %{"id" => id}, socket) do
    task = get_scoped_task!(socket, id)
    due_at_str = if task.due_at, do: format_datetime_local(task.due_at), else: ""

    {:noreply,
     socket
     |> assign(:editing_task_id, task.id)
     |> assign(:edit_task_title, task.title)
     |> assign(:edit_task_due_at, due_at_str)
     |> assign(:edit_task_portal_visible, task.portal_visible)}
  end

  def handle_event("cancel_edit_task", _params, socket) do
    {:noreply, assign(socket, :editing_task_id, nil)}
  end

  def handle_event("update_edit_task", params, socket) do
    socket =
      socket
      |> assign(:edit_task_title, params["title"] || socket.assigns.edit_task_title)
      |> assign(:edit_task_due_at, params["due_at"] || socket.assigns.edit_task_due_at)
      |> assign(:edit_task_portal_visible, params["portal_visible"] == "true")

    {:noreply, socket}
  end

  def handle_event("save_task", params, socket) do
    title = params["title"] || ""

    if byte_size(title) > 0 do
      task = get_scoped_task!(socket, socket.assigns.editing_task_id)
      due_at = parse_due_at(params["due_at"])
      portal_visible = params["portal_visible"] == "true"

      case Conversations.update_task(task, %{
             title: title,
             due_at: due_at,
             portal_visible: portal_visible
           }) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:editing_task_id, nil)
           |> reload_conversation()}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to save task")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete_task", %{"id" => id}, socket) do
    task = get_scoped_task!(socket, id)

    case Conversations.delete_task(task) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:editing_task_id, nil)
         |> reload_conversation()}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to delete task")}
    end
  end

  @impl true
  def handle_info({:message_added, _id}, socket) do
    {:noreply, reload_conversation(socket)}
  end

  # Broadcast by Email.Outbound when async delivery resolves, so the
  # pending/sent/failed indicator updates without a manual refresh.
  def handle_info({:message_updated, _id}, socket) do
    {:noreply, reload_conversation(socket)}
  end

  def handle_info({:conversation_updated, id}, socket) do
    if id == socket.assigns.conversation.id do
      {:noreply, reload_conversation(socket)}
    else
      {:noreply, socket}
    end
  end

  defp get_scoped_task!(socket, task_id) when is_binary(task_id) do
    case Integer.parse(task_id) do
      {int_id, ""} -> get_scoped_task!(socket, int_id)
      _ -> raise Ecto.NoResultsError, queryable: Custyard.Task
    end
  end

  defp get_scoped_task!(socket, task_id) when is_integer(task_id) do
    task = Conversations.get_task!(task_id)
    conversation_id = socket.assigns.conversation.id

    unless task.conversation_id == conversation_id do
      raise Ecto.NoResultsError, queryable: Custyard.Task
    end

    task
  end

  # A reply is recorded in the thread even without a contact email, but the
  # async delivery will fail — warn the operator up front.
  defp deliverable_recipient?(conversation) do
    case conversation.contact do
      %{email: email} when is_binary(email) and email != "" -> true
      _ -> false
    end
  end

  defp load_conversation(id) do
    Conversations.get_with_messages(id)
  rescue
    Ecto.NoResultsError -> nil
  end

  defp reload_conversation(socket) do
    case load_conversation(socket.assigns.conversation.id) do
      nil ->
        # Conversation was deleted - redirect to queue
        socket
        |> put_flash(:error, "Conversation no longer exists")
        |> push_navigate(to: ~p"/operator")

      conversation ->
        breakdown = Scoring.breakdown(conversation)
        neglect_status = Scoring.neglect_status(conversation)
        other_conversations = fetch_other_org_conversations(conversation)

        socket
        |> assign(:conversation, conversation)
        |> assign(:breakdown, breakdown)
        |> assign(:neglect_status, neglect_status)
        |> assign(:other_conversations, other_conversations)
    end
  end

  # Unlinked (nil-org) conversations have no sibling org conversations to list.
  defp fetch_other_org_conversations(%{organization_id: nil}), do: []

  defp fetch_other_org_conversations(conversation) do
    conversation.organization_id
    |> Conversations.list_for_organization(include_resolved: false)
    |> Enum.reject(&(&1.id == conversation.id))
    |> Enum.take(5)
  end

  # Truncate subject for page title (browser tab)
  defp truncate_subject(subject) when byte_size(subject) <= 50, do: subject

  defp truncate_subject(subject) do
    String.slice(subject, 0, 47) <> "..."
  end

  # NOTE: Timezone handling
  # datetime-local inputs provide local time without timezone info.
  # We treat them as UTC for storage and display, which is consistent but
  # means users in non-UTC timezones will see times offset from their local.
  # TODO: For proper timezone support, send user's timezone from client
  # and convert local <-> UTC on save/display.
  defp parse_due_at(nil), do: nil
  defp parse_due_at(""), do: nil

  defp parse_due_at(date_str) when is_binary(date_str) do
    # Append "Z" to treat input as UTC
    case DateTime.from_iso8601(date_str <> ":00Z") do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  # Formats datetime for datetime-local input (displays as UTC)
  defp format_datetime_local(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%dT%H:%M")
  end

  # Formats due date for display (relative to UTC now)
  defp format_due_at(datetime) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    diff_days = Date.diff(DateTime.to_date(datetime), DateTime.to_date(now))

    cond do
      diff_days < 0 -> "overdue by #{abs(diff_days)}d"
      diff_days == 0 -> "today"
      diff_days == 1 -> "tomorrow"
      diff_days < 7 -> Calendar.strftime(datetime, "%A")
      true -> Calendar.strftime(datetime, "%b %d")
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex flex-1 min-h-0" data-testid="operator-conversation-page">
      <%!-- Left: message thread --%>
      <div class="flex-1 flex flex-col min-w-0" data-testid="operator-conversation-thread">
        <div class="border-b border-gray-200 dark:border-zinc-700 px-4 py-3 flex items-center gap-3 bg-white dark:bg-zinc-800">
          <.link
            navigate={~p"/operator"}
            class="text-sm text-gray-500 dark:text-zinc-400 hover:text-gray-700 dark:hover:text-zinc-200"
            data-testid="operator-conversation-back"
          >
            &larr; Queue
          </.link>
          <span
            class="font-semibold text-gray-900 dark:text-zinc-100 truncate flex-1"
            data-testid="operator-conversation-subject"
          >
            {@conversation.subject}
          </span>
          <.source_badge source={@conversation.source} />
          <.state_badge state={@conversation.state} />
          <button
            phx-click="toggle_sidebar"
            class="lg:hidden text-gray-500 dark:text-zinc-400 hover:text-gray-700 dark:hover:text-zinc-200 p-1"
            aria-label="Toggle details panel"
            data-testid="operator-sidebar-toggle"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="h-5 w-5"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M13 16h-1v-4h-1m1-4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
              />
            </svg>
          </button>
        </div>

        <div
          id="message-thread"
          phx-hook="ScrollBottom"
          class="flex-1 overflow-y-auto px-4 py-4 bg-gray-50 dark:bg-zinc-800 space-y-1"
          data-testid="operator-conversation-messages"
        >
          <div
            :if={@conversation.messages == []}
            class="text-center py-8 text-gray-500 dark:text-zinc-400"
            data-testid="operator-no-messages"
          >
            No messages yet
          </div>
          <%= for message <- @conversation.messages do %>
            <.message_bubble message={message} />
          <% end %>
        </div>

        <div class="border-t border-gray-200 dark:border-zinc-700 p-3 space-y-2 bg-white dark:bg-zinc-800">
          <form phx-submit="send_reply" class="flex gap-2" data-testid="operator-reply-form">
            <textarea
              name="body"
              rows="2"
              phx-change="update_reply"
              phx-hook="CtrlEnterSubmit"
              id="operator-reply-textarea"
              placeholder="Reply to customer... (Ctrl+Enter to send)"
              aria-label="Reply to customer"
              data-testid="operator-reply-input"
              class="flex-1 border border-gray-300 dark:border-zinc-600 rounded px-3 py-2 text-sm resize-y dark:bg-zinc-700 dark:text-zinc-100"
            >{@reply_text}</textarea>
            <button
              type="submit"
              phx-disable-with="Sending..."
              class="bg-indigo-600 text-white text-sm px-4 py-2 rounded hover:bg-indigo-700"
              data-testid="operator-reply-submit"
            >
              Send
            </button>
          </form>

          <form phx-submit="add_note" class="flex gap-2" data-testid="operator-note-form">
            <input
              type="text"
              name="body"
              value={@note_text}
              phx-change="update_note"
              phx-hook="CtrlEnterSubmit"
              id="operator-note-input"
              placeholder="Internal note (Ctrl+Enter to save)..."
              aria-label="Internal note (not visible to customer)"
              data-testid="operator-note-input"
              class="flex-1 border border-amber-300 dark:border-amber-700 bg-amber-50 dark:bg-amber-900/30 dark:text-zinc-100 rounded px-3 py-2 text-sm"
            />
            <button
              type="submit"
              phx-disable-with="Saving..."
              class="bg-amber-500 text-white text-sm px-4 py-2 rounded hover:bg-amber-600"
              data-testid="operator-note-submit"
            >
              Note
            </button>
          </form>
        </div>
      </div>

      <%!-- Mobile sidebar overlay --%>
      <div
        :if={@show_sidebar}
        class="lg:hidden fixed inset-0 z-40 bg-black/50"
        phx-click="toggle_sidebar"
        data-testid="operator-sidebar-backdrop"
      />

      <%!-- Right: metadata panel --%>
      <div
        class={[
          "w-72 border-l border-gray-200 dark:border-zinc-700 bg-white dark:bg-zinc-800 overflow-y-auto",
          "lg:block lg:relative",
          if(@show_sidebar,
            do: "fixed right-0 top-0 bottom-0 z-50",
            else: "hidden"
          )
        ]}
        data-testid="operator-conversation-sidebar"
      >
        <%!-- Mobile close button --%>
        <div class="lg:hidden flex justify-between items-center p-3 border-b border-gray-200 dark:border-zinc-700">
          <span class="font-medium text-gray-700 dark:text-zinc-300">Details</span>
          <button
            phx-click="toggle_sidebar"
            class="text-gray-500 dark:text-zinc-400 hover:text-gray-700 dark:hover:text-zinc-200 p-1"
            aria-label="Close details panel"
            data-testid="operator-sidebar-close"
          >
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="h-5 w-5"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M6 18L18 6M6 6l12 12"
              />
            </svg>
          </button>
        </div>
        <div class="p-4 space-y-4">
          <%!-- Organization --%>
          <div data-testid="operator-sidebar-org">
            <div class="text-xs text-gray-400 dark:text-zinc-500 uppercase tracking-wide mb-1">
              Organization
            </div>
            <%= if @conversation.organization do %>
              <.link
                navigate={~p"/operator/organizations/#{@conversation.organization.id}"}
                class="text-sm text-indigo-600 hover:underline font-medium"
                data-testid="operator-sidebar-org-link"
              >
                {@conversation.organization.name}
              </.link>
              <div class="mt-1">
                <.tier_badge tier={@conversation.organization.tier} />
              </div>
            <% else %>
              <div
                class="text-sm font-medium text-gray-800 dark:text-zinc-200"
                data-testid="operator-sidebar-org-unlinked"
              >
                Unlinked prospect
              </div>
            <% end %>
          </div>

          <%!-- Contact --%>
          <div data-testid="operator-sidebar-contact">
            <div class="text-xs text-gray-400 dark:text-zinc-500 uppercase tracking-wide mb-1">
              Contact
            </div>
            <div class="text-sm text-gray-800 dark:text-zinc-200">
              {if @conversation.contact,
                do: @conversation.contact.name || @conversation.contact.email,
                else: "Unknown"}
            </div>
            <%= if @conversation.contact && @conversation.contact.email do %>
              <div
                class="text-xs text-gray-500 dark:text-zinc-400"
                data-testid="operator-sidebar-contact-email"
              >
                {@conversation.contact.email}
              </div>
            <% end %>
          </div>

          <%!-- State actions --%>
          <div>
            <div class="text-xs text-gray-400 dark:text-zinc-500 uppercase tracking-wide mb-2">
              Actions
            </div>
            <div class="space-y-1.5" data-testid="operator-state-actions">
              <%= if @conversation.state == :resolved do %>
                <button
                  phx-click="set_state"
                  phx-value-state="active"
                  class="w-full text-left text-sm px-3 py-1.5 rounded bg-blue-50 hover:bg-blue-100 text-blue-800 border border-blue-200"
                  data-testid="operator-state-reopen"
                >
                  Reopen
                </button>
              <% else %>
                <button
                  phx-click="set_state"
                  phx-value-state="waiting"
                  class="w-full text-left text-sm px-3 py-1.5 rounded bg-yellow-50 hover:bg-yellow-100 text-yellow-800 border border-yellow-200"
                  data-testid="operator-state-waiting"
                >
                  Waiting on customer
                </button>
                <button
                  phx-click="set_state"
                  phx-value-state="resolved"
                  data-confirm="Mark this conversation as resolved?"
                  class="w-full text-left text-sm px-3 py-1.5 rounded bg-green-50 hover:bg-green-100 text-green-800 border border-green-200"
                  data-testid="operator-state-resolved"
                >
                  Mark resolved
                </button>
              <% end %>
            </div>
          </div>

          <%!-- Tasks --%>
          <div>
            <div
              class="text-xs text-gray-400 dark:text-zinc-500 uppercase tracking-wide mb-2"
              data-testid="operator-tasks-section"
            >
              Tasks ({length(@conversation.tasks)})
            </div>
            <%= if Enum.empty?(@conversation.tasks) do %>
              <div class="text-xs text-gray-400 dark:text-zinc-500">No tasks yet</div>
            <% else %>
              <div class="space-y-2">
                <%= for task <- @conversation.tasks do %>
                  <%= if @editing_task_id == task.id do %>
                    <.task_edit_form
                      task={task}
                      title={@edit_task_title}
                      due_at={@edit_task_due_at}
                      portal_visible={@edit_task_portal_visible}
                    />
                  <% else %>
                    <.task_item task={task} />
                  <% end %>
                <% end %>
              </div>
            <% end %>

            <%= if @show_task_form do %>
              <form
                phx-submit="add_task"
                phx-change="update_new_task"
                class="mt-3 space-y-2 p-2 bg-gray-50 dark:bg-zinc-800 rounded border border-gray-200 dark:border-zinc-700"
                data-testid="operator-task-form"
              >
                <input
                  type="text"
                  name="title"
                  value={@new_task_title}
                  placeholder="Task title..."
                  aria-label="Task title"
                  class="w-full text-xs border border-gray-300 dark:border-zinc-600 rounded px-2 py-1"
                  autofocus
                  data-testid="operator-task-title-input"
                />
                <div class="flex gap-2">
                  <input
                    type="datetime-local"
                    name="due_at"
                    value={@new_task_due_at}
                    aria-label="Due date"
                    class="flex-1 text-xs border border-gray-300 dark:border-zinc-600 rounded px-2 py-1"
                    data-testid="operator-task-due-input"
                  />
                </div>
                <div class="flex items-center gap-2">
                  <input type="hidden" name="portal_visible" value="false" />
                  <input
                    type="checkbox"
                    name="portal_visible"
                    value="true"
                    checked={@new_task_portal_visible}
                    id="new_task_portal_visible"
                    class="h-3 w-3"
                    data-testid="operator-task-visible-checkbox"
                  />
                  <label
                    for="new_task_portal_visible"
                    class="text-xs text-gray-600 dark:text-zinc-400"
                  >
                    Visible in portal
                  </label>
                </div>
                <div class="flex gap-2">
                  <button
                    type="submit"
                    class="text-xs bg-indigo-600 text-white px-2 py-1 rounded hover:bg-indigo-700"
                    data-testid="operator-task-add-btn"
                  >
                    Add
                  </button>
                  <button
                    type="button"
                    phx-click="toggle_task_form"
                    class="text-xs text-gray-500 dark:text-zinc-400 hover:text-gray-700 dark:hover:text-zinc-200"
                    data-testid="operator-task-cancel-btn"
                  >
                    Cancel
                  </button>
                </div>
              </form>
            <% else %>
              <button
                phx-click="toggle_task_form"
                class="mt-2 text-xs text-indigo-600 hover:underline"
                data-testid="operator-add-task-btn"
              >
                + Add task
              </button>
            <% end %>
          </div>

          <%!-- Other open conversations for this org --%>
          <div :if={@other_conversations != []} data-testid="operator-sidebar-other-conversations">
            <div class="text-xs text-gray-400 dark:text-zinc-500 uppercase tracking-wide mb-2">
              Other Open ({length(@other_conversations)})
            </div>
            <div class="space-y-1.5">
              <.link
                :for={conv <- @other_conversations}
                navigate={~p"/operator/conversation/#{conv.id}"}
                class="block text-sm text-gray-700 dark:text-zinc-300 hover:text-indigo-600 dark:hover:text-indigo-400 truncate"
                data-testid={"operator-other-conv-#{conv.id}"}
              >
                <span
                  class="inline-block w-2 h-2 rounded-full mr-1.5"
                  style={state_dot_color(conv.state)}
                />
                {conv.subject}
              </.link>
            </div>
          </div>

          <%!-- Neglect status --%>
          <%= if @neglect_status != :ok do %>
            <div data-testid="operator-sidebar-neglect">
              <div class="text-xs text-gray-400 dark:text-zinc-500 uppercase tracking-wide mb-1">
                Status
              </div>
              <.neglect_badge level={@neglect_status} />
            </div>
          <% end %>

          <%!-- Score breakdown --%>
          <.score_breakdown breakdown={@breakdown} />
        </div>
      </div>
    </div>
    """
  end

  attr :message, Message, required: true

  defp message_bubble(assigns) do
    is_operator = assigns.message.source == :operator
    is_internal = assigns.message.is_internal_note

    bg_class =
      cond do
        is_internal ->
          "bg-amber-50 dark:bg-amber-900/30 border-amber-200 dark:border-amber-700"

        is_operator ->
          "bg-indigo-50 dark:bg-indigo-900/30 border-indigo-100 dark:border-indigo-700"

        true ->
          "bg-white dark:bg-zinc-800 border-gray-200 dark:border-zinc-700"
      end

    assigns =
      assigns
      |> assign(:is_operator, is_operator)
      |> assign(:is_internal, is_internal)
      |> assign(:bg_class, bg_class)

    ~H"""
    <div
      class={"flex #{if @is_operator, do: "justify-end", else: "justify-start"} mb-3"}
      data-testid={"operator-message-#{@message.id}"}
    >
      <div
        class={"max-w-lg rounded-lg px-4 py-2.5 border #{@bg_class}"}
        data-testid={"operator-message-#{if @is_internal, do: "internal", else: to_string(@message.source)}"}
      >
        <div class="flex items-center gap-2 mb-1">
          <span
            class={"text-xs font-medium #{if @is_operator, do: "text-indigo-700", else: "text-gray-700 dark:text-zinc-300"}"}
            data-testid="operator-message-sender"
          >
            {sender_name(@message)}
          </span>
          <%= if @is_internal do %>
            <span
              class="text-xs bg-amber-200 text-amber-800 px-1.5 py-0.5 rounded"
              data-testid="operator-message-internal-badge"
            >
              internal note
            </span>
          <% end %>
          <span class="text-xs text-gray-400 dark:text-zinc-500">
            {unless @is_internal, do: "via #{@message.source}"}
          </span>
          <span
            class="text-xs text-gray-400 dark:text-zinc-500 ml-auto"
            data-testid="operator-message-time"
          >
            {format_time(@message.inserted_at)}
          </span>
          <.delivery_indicator
            :if={@is_operator and not @is_internal and @message.delivery_status}
            status={@message.delivery_status}
          />
        </div>
        <div
          class="text-sm text-gray-800 dark:text-zinc-200 whitespace-pre-wrap break-words"
          data-testid="operator-message-body"
        >
          {@message.body}
        </div>
      </div>
    </div>
    """
  end

  attr :status, :atom, required: true, values: [:pending, :sent, :failed, :bounced]

  defp delivery_indicator(%{status: :pending} = assigns) do
    ~H"""
    <span
      class="inline-flex items-center text-xs text-gray-400 dark:text-zinc-500"
      title="Sending..."
      data-testid="delivery-status-pending"
    >
      <svg
        class="h-3.5 w-3.5 animate-spin"
        xmlns="http://www.w3.org/2000/svg"
        fill="none"
        viewBox="0 0 24 24"
      >
        <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4" />
        <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z" />
      </svg>
    </span>
    """
  end

  defp delivery_indicator(%{status: :sent} = assigns) do
    ~H"""
    <span
      class="inline-flex items-center text-xs text-green-500 dark:text-green-400"
      title="Sent"
      data-testid="delivery-status-sent"
    >
      <svg
        class="h-3.5 w-3.5"
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 20 20"
        fill="currentColor"
      >
        <path
          fill-rule="evenodd"
          d="M16.704 4.153a.75.75 0 01.143 1.052l-8 10.5a.75.75 0 01-1.127.075l-4.5-4.5a.75.75 0 011.06-1.06l3.894 3.893 7.48-9.817a.75.75 0 011.05-.143z"
          clip-rule="evenodd"
        />
      </svg>
    </span>
    """
  end

  defp delivery_indicator(%{status: :failed} = assigns) do
    ~H"""
    <span
      class="inline-flex items-center text-xs text-red-500 dark:text-red-400"
      title="Delivery failed"
      data-testid="delivery-status-failed"
    >
      <svg
        class="h-3.5 w-3.5"
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 20 20"
        fill="currentColor"
      >
        <path
          fill-rule="evenodd"
          d="M18 10a8 8 0 11-16 0 8 8 0 0116 0zm-8-5a.75.75 0 01.75.75v4.5a.75.75 0 01-1.5 0v-4.5A.75.75 0 0110 5zm0 10a1 1 0 100-2 1 1 0 000 2z"
          clip-rule="evenodd"
        />
      </svg>
    </span>
    """
  end

  defp delivery_indicator(%{status: :bounced} = assigns) do
    ~H"""
    <span
      class="inline-flex items-center text-xs text-amber-500 dark:text-amber-400"
      title="Email bounced"
      data-testid="delivery-status-bounced"
    >
      <svg
        class="h-3.5 w-3.5"
        xmlns="http://www.w3.org/2000/svg"
        viewBox="0 0 20 20"
        fill="currentColor"
      >
        <path
          fill-rule="evenodd"
          d="M8.485 2.495c.673-1.167 2.357-1.167 3.03 0l6.28 10.875c.673 1.167-.17 2.625-1.516 2.625H3.72c-1.347 0-2.189-1.458-1.515-2.625L8.485 2.495zM10 5a.75.75 0 01.75.75v3.5a.75.75 0 01-1.5 0v-3.5A.75.75 0 0110 5zm0 9a1 1 0 100-2 1 1 0 000 2z"
          clip-rule="evenodd"
        />
      </svg>
    </span>
    """
  end

  defp next_task_state(:open), do: "in progress"
  defp next_task_state(:in_progress), do: "done"
  defp next_task_state(:done), do: "open"
  defp next_task_state(_), do: "in progress"

  defp sender_name(message) do
    cond do
      message.source == :operator -> "You"
      message.sender_email -> message.sender_email
      true -> "Customer"
    end
  end

  defp format_time(datetime) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    diff_days = Date.diff(DateTime.to_date(now), DateTime.to_date(datetime))

    cond do
      diff_days == 0 -> Calendar.strftime(datetime, "%I:%M %p")
      diff_days == 1 -> Calendar.strftime(datetime, "Yesterday %I:%M %p")
      diff_days < 7 -> Calendar.strftime(datetime, "%a %I:%M %p")
      true -> Calendar.strftime(datetime, "%b %d")
    end
  end

  attr :task, :map, required: true

  defp task_item(assigns) do
    ~H"""
    <div
      class="group flex items-start gap-2 text-sm p-1 rounded hover:bg-gray-50 dark:hover:bg-zinc-700"
      data-testid={"operator-task-item-#{@task.id}"}
    >
      <button
        phx-click="toggle_task"
        phx-value-id={@task.id}
        class="mt-0.5 shrink-0"
        title="Cycle state: open -> in_progress -> done"
        aria-label={"Task status: #{@task.state}. Click to change to #{next_task_state(@task.state)}."}
      >
        <.task_status_dot state={@task.state} />
      </button>
      <div class="flex-1 min-w-0">
        <span class={"text-gray-700 dark:text-zinc-300 #{if @task.state == :done, do: "line-through opacity-50"}"}>
          {@task.title}
        </span>
        <%= if @task.due_at do %>
          <div class="text-xs text-gray-400 dark:text-zinc-500">
            Due: {format_due_at(@task.due_at)}
          </div>
        <% end %>
      </div>
      <div class="flex items-center gap-1 opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 transition-opacity">
        <%= if @task.portal_visible do %>
          <span
            class="text-xs text-gray-400 dark:text-zinc-500"
            title="Visible in portal"
            data-testid="operator-task-visible-icon"
          >
            <.icon name="hero-eye" class="h-3 w-3" />
          </span>
        <% else %>
          <span
            class="text-xs text-gray-300 dark:text-zinc-600"
            title="Hidden from portal"
            data-testid="operator-task-hidden-icon"
          >
            <.icon name="hero-eye-slash" class="h-3 w-3" />
          </span>
        <% end %>
        <button
          phx-click="edit_task"
          phx-value-id={@task.id}
          class="text-gray-400 dark:text-zinc-500 hover:text-indigo-600"
          title="Edit task"
          data-testid={"operator-task-edit-#{@task.id}"}
        >
          <.icon name="hero-pencil" class="h-3 w-3" />
        </button>
        <button
          phx-click="delete_task"
          phx-value-id={@task.id}
          data-confirm="Delete this task?"
          class="text-gray-400 dark:text-zinc-500 hover:text-red-600"
          title="Delete task"
          data-testid={"operator-task-delete-#{@task.id}"}
        >
          <.icon name="hero-trash" class="h-3 w-3" />
        </button>
      </div>
    </div>
    """
  end

  attr :task, :map, required: true
  attr :title, :string, required: true
  attr :due_at, :string, required: true
  attr :portal_visible, :boolean, required: true

  defp task_edit_form(assigns) do
    ~H"""
    <form
      phx-submit="save_task"
      phx-change="update_edit_task"
      class="p-2 bg-indigo-50 dark:bg-indigo-900/30 rounded border border-indigo-200 dark:border-indigo-700 space-y-2"
      data-testid={"operator-task-edit-form-#{@task.id}"}
    >
      <input
        type="text"
        name="title"
        value={@title}
        placeholder="Task title..."
        aria-label="Task title"
        class="w-full text-xs border border-gray-300 dark:border-zinc-600 rounded px-2 py-1"
        autofocus
        data-testid="operator-task-edit-title"
      />
      <input
        type="datetime-local"
        name="due_at"
        value={@due_at}
        aria-label="Due date"
        class="w-full text-xs border border-gray-300 dark:border-zinc-600 rounded px-2 py-1"
        data-testid="operator-task-edit-due"
      />
      <div class="flex items-center gap-2">
        <input type="hidden" name="portal_visible" value="false" />
        <input
          type="checkbox"
          name="portal_visible"
          value="true"
          checked={@portal_visible}
          id={"edit_task_portal_visible_#{@task.id}"}
          class="h-3 w-3"
          data-testid="operator-task-edit-visible"
        />
        <label
          for={"edit_task_portal_visible_#{@task.id}"}
          class="text-xs text-gray-600 dark:text-zinc-400"
        >
          Visible in portal
        </label>
      </div>
      <div class="flex gap-2">
        <button
          type="submit"
          class="text-xs bg-indigo-600 text-white px-2 py-1 rounded hover:bg-indigo-700"
          data-testid="operator-task-edit-save"
        >
          Save
        </button>
        <button
          type="button"
          phx-click="cancel_edit_task"
          class="text-xs text-gray-500 dark:text-zinc-400 hover:text-gray-700 dark:hover:text-zinc-200"
          data-testid="operator-task-edit-cancel"
        >
          Cancel
        </button>
        <button
          type="button"
          phx-click="delete_task"
          phx-value-id={@task.id}
          data-confirm="Delete this task?"
          class="text-xs text-red-500 hover:text-red-700 ml-auto"
          data-testid="operator-task-edit-delete"
        >
          Delete
        </button>
      </div>
    </form>
    """
  end

  attr :state, :atom, required: true

  defp task_status_dot(assigns) do
    color =
      case assigns.state do
        :done -> "bg-green-400"
        :in_progress -> "bg-blue-400"
        :open -> "bg-gray-300 dark:bg-zinc-600"
        _ -> "bg-gray-300 dark:bg-zinc-600"
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <span class={"w-2 h-2 rounded-full #{@color}"} data-testid={"operator-task-dot-#{@state}"} />
    """
  end

  defp state_dot_color(state) do
    color =
      case state do
        :new -> "#3B82F6"
        :active -> "#22C55E"
        :waiting -> "#EAB308"
        :dormant -> "#9CA3AF"
        :resolved -> "#D1D5DB"
        _ -> "#9CA3AF"
      end

    "background-color: #{color}"
  end
end
