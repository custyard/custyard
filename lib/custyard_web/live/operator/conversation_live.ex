defmodule CustyardWeb.Operator.ConversationLive do
  use CustyardWeb, :live_view

  alias Custyard.{Conversations, Message, Scoring}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Custyard.PubSub, "conversations")
      Phoenix.PubSub.subscribe(Custyard.PubSub, "conversation:#{id}")
    end

    conversation = load_conversation(id)

    # Transition new to active when operator views
    conversation =
      if conversation.state == :new do
        now = DateTime.utc_now() |> DateTime.truncate(:second)

        {:ok, updated} =
          Conversations.update_conversation(conversation,
            state: :active,
            last_operator_action_at: now
          )

        Scoring.calculate_and_cache(updated.id)

        Phoenix.PubSub.broadcast(
          Custyard.PubSub,
          "conversations",
          {:conversation_updated, updated.id}
        )

        load_conversation(id)
      else
        conversation
      end

    breakdown = Scoring.breakdown(conversation)
    neglect_status = Scoring.neglect_status(conversation)

    socket =
      socket
      |> assign(:conversation, conversation)
      |> assign(:breakdown, breakdown)
      |> assign(:neglect_status, neglect_status)
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

    {:ok, socket, layout: {CustyardWeb.Layouts, :operator}}
  end

  @impl true
  def handle_event("send_reply", %{"body" => body}, socket) when byte_size(body) > 0 do
    conversation = socket.assigns.conversation

    {:ok, _message} =
      Conversations.create_message(%{
        source: :operator,
        body: body,
        is_internal_note: false,
        conversation_id: conversation.id
      })

    # Update last_operator_action_at and ensure state is active
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, _} =
      Conversations.update_conversation(conversation,
        last_operator_action_at: now,
        state: :active
      )

    Scoring.calculate_and_cache(conversation.id)

    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "conversation:#{conversation.id}",
      {:message_added, conversation.id}
    )

    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "conversations",
      {:conversation_updated, conversation.id}
    )

    {:noreply, socket |> assign(:reply_text, "") |> reload_conversation()}
  end

  def handle_event("send_reply", _params, socket), do: {:noreply, socket}

  def handle_event("add_note", %{"body" => body}, socket) when byte_size(body) > 0 do
    conversation = socket.assigns.conversation

    {:ok, _message} =
      Conversations.create_message(%{
        source: :operator,
        body: body,
        is_internal_note: true,
        conversation_id: conversation.id
      })

    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "conversation:#{conversation.id}",
      {:message_added, conversation.id}
    )

    {:noreply, socket |> assign(:note_text, "") |> reload_conversation()}
  end

  def handle_event("add_note", _params, socket), do: {:noreply, socket}

  def handle_event("update_reply", %{"body" => body}, socket) do
    {:noreply, assign(socket, :reply_text, body)}
  end

  def handle_event("update_note", %{"body" => body}, socket) do
    {:noreply, assign(socket, :note_text, body)}
  end

  def handle_event("set_state", %{"state" => state}, socket) do
    conversation = socket.assigns.conversation
    new_state = String.to_existing_atom(state)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {:ok, _} =
      Conversations.update_conversation(conversation,
        state: new_state,
        last_operator_action_at: now
      )

    Scoring.calculate_and_cache(conversation.id)

    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "conversations",
      {:conversation_updated, conversation.id}
    )

    {:noreply, reload_conversation(socket)}
  end

  def handle_event("toggle_task_form", _params, socket) do
    {:noreply, assign(socket, :show_task_form, !socket.assigns.show_task_form)}
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

      {:ok, _task} =
        Conversations.create_task(%{
          title: title,
          due_at: due_at,
          portal_visible: portal_visible,
          conversation_id: conversation.id
        })

      {:noreply,
       socket
       |> assign(:new_task_title, "")
       |> assign(:new_task_due_at, "")
       |> assign(:new_task_portal_visible, true)
       |> assign(:show_task_form, false)
       |> reload_conversation()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_task", %{"id" => id}, socket) do
    task = Conversations.get_task!(id)

    new_state =
      case task.state do
        :open -> :in_progress
        :in_progress -> :done
        :done -> :open
      end

    {:ok, _} = Conversations.update_task_state(task, new_state)

    {:noreply, reload_conversation(socket)}
  end

  def handle_event("edit_task", %{"id" => id}, socket) do
    task = Conversations.get_task!(id)
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
      task = Conversations.get_task!(socket.assigns.editing_task_id)
      due_at = parse_due_at(params["due_at"])
      portal_visible = params["portal_visible"] == "true"

      {:ok, _} =
        Conversations.update_task(task, %{
          title: title,
          due_at: due_at,
          portal_visible: portal_visible
        })

      {:noreply,
       socket
       |> assign(:editing_task_id, nil)
       |> reload_conversation()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("delete_task", %{"id" => id}, socket) do
    task = Conversations.get_task!(id)
    {:ok, _} = Conversations.delete_task(task)

    {:noreply,
     socket
     |> assign(:editing_task_id, nil)
     |> reload_conversation()}
  end

  @impl true
  def handle_info({:message_added, _id}, socket) do
    {:noreply, reload_conversation(socket)}
  end

  def handle_info({:conversation_updated, id}, socket) do
    if id == socket.assigns.conversation.id do
      {:noreply, reload_conversation(socket)}
    else
      {:noreply, socket}
    end
  end

  defp load_conversation(id) do
    Conversations.get_with_messages(id)
  end

  defp reload_conversation(socket) do
    conversation = load_conversation(socket.assigns.conversation.id)
    breakdown = Scoring.breakdown(conversation)
    neglect_status = Scoring.neglect_status(conversation)

    socket
    |> assign(:conversation, conversation)
    |> assign(:breakdown, breakdown)
    |> assign(:neglect_status, neglect_status)
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
    <div class="flex h-full">
      <%!-- Left: message thread --%>
      <div class="flex-1 flex flex-col min-w-0">
        <div class="border-b border-gray-200 px-4 py-3 flex items-center gap-3 bg-white">
          <.link navigate={~p"/operator"} class="text-sm text-gray-500 hover:text-gray-700">
            &larr; Queue
          </.link>
          <span class="font-semibold text-gray-900 truncate">{@conversation.subject}</span>
          <.state_badge state={@conversation.state} />
        </div>

        <div class="flex-1 overflow-y-auto px-4 py-4 bg-gray-50 space-y-1">
          <%= for message <- @conversation.messages do %>
            <.message_bubble message={message} />
          <% end %>
        </div>

        <div class="border-t border-gray-200 p-3 space-y-2 bg-white">
          <form phx-submit="send_reply" class="flex gap-2">
            <input
              type="text"
              name="body"
              value={@reply_text}
              phx-change="update_reply"
              placeholder="Reply to customer..."
              class="flex-1 border border-gray-300 rounded px-3 py-2 text-sm"
            />
            <button
              type="submit"
              class="bg-indigo-600 text-white text-sm px-4 py-2 rounded hover:bg-indigo-700"
            >
              Send
            </button>
          </form>

          <form phx-submit="add_note" class="flex gap-2">
            <input
              type="text"
              name="body"
              value={@note_text}
              phx-change="update_note"
              placeholder="Internal note (not visible to customer)..."
              class="flex-1 border border-amber-300 bg-amber-50 rounded px-3 py-2 text-sm"
            />
            <button
              type="submit"
              class="bg-amber-500 text-white text-sm px-4 py-2 rounded hover:bg-amber-600"
            >
              Note
            </button>
          </form>
        </div>
      </div>

      <%!-- Right: metadata panel --%>
      <div class="w-72 border-l border-gray-200 bg-white overflow-y-auto">
        <div class="p-4 space-y-4">
          <%!-- Organization --%>
          <div>
            <div class="text-xs text-gray-400 uppercase tracking-wide mb-1">Organization</div>
            <.link
              navigate={~p"/operator/organizations"}
              class="text-sm text-indigo-600 hover:underline font-medium"
            >
              {@conversation.organization.name}
            </.link>
            <div class="mt-1">
              <.tier_badge tier={@conversation.organization.tier} />
            </div>
          </div>

          <%!-- Contact --%>
          <div>
            <div class="text-xs text-gray-400 uppercase tracking-wide mb-1">Contact</div>
            <div class="text-sm text-gray-800">
              {if @conversation.contact,
                do: @conversation.contact.name || @conversation.contact.email,
                else: "Unknown"}
            </div>
            <%= if @conversation.contact && @conversation.contact.email do %>
              <div class="text-xs text-gray-500">{@conversation.contact.email}</div>
            <% end %>
          </div>

          <%!-- State actions --%>
          <div>
            <div class="text-xs text-gray-400 uppercase tracking-wide mb-2">Actions</div>
            <div class="space-y-1.5">
              <button
                phx-click="set_state"
                phx-value-state="waiting"
                class="w-full text-left text-sm px-3 py-1.5 rounded bg-yellow-50 hover:bg-yellow-100 text-yellow-800 border border-yellow-200"
              >
                Waiting on customer
              </button>
              <button
                phx-click="set_state"
                phx-value-state="resolved"
                class="w-full text-left text-sm px-3 py-1.5 rounded bg-green-50 hover:bg-green-100 text-green-800 border border-green-200"
              >
                Mark resolved
              </button>
            </div>
          </div>

          <%!-- Tasks --%>
          <div>
            <div class="text-xs text-gray-400 uppercase tracking-wide mb-2">
              Tasks ({length(@conversation.tasks)})
            </div>
            <%= if Enum.empty?(@conversation.tasks) do %>
              <div class="text-xs text-gray-400">No tasks yet</div>
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
                class="mt-3 space-y-2 p-2 bg-gray-50 rounded border border-gray-200"
              >
                <input
                  type="text"
                  name="title"
                  value={@new_task_title}
                  placeholder="Task title..."
                  class="w-full text-xs border border-gray-300 rounded px-2 py-1"
                  autofocus
                />
                <div class="flex gap-2">
                  <input
                    type="datetime-local"
                    name="due_at"
                    value={@new_task_due_at}
                    class="flex-1 text-xs border border-gray-300 rounded px-2 py-1"
                  />
                </div>
                <div class="flex items-center gap-2">
                  <input
                    type="checkbox"
                    name="portal_visible"
                    value="true"
                    checked={@new_task_portal_visible}
                    id="new_task_portal_visible"
                    class="h-3 w-3"
                  />
                  <label for="new_task_portal_visible" class="text-xs text-gray-600">
                    Visible in portal
                  </label>
                </div>
                <div class="flex gap-2">
                  <button
                    type="submit"
                    class="text-xs bg-indigo-600 text-white px-2 py-1 rounded hover:bg-indigo-700"
                  >
                    Add
                  </button>
                  <button
                    type="button"
                    phx-click="toggle_task_form"
                    class="text-xs text-gray-500 hover:text-gray-700"
                  >
                    Cancel
                  </button>
                </div>
              </form>
            <% else %>
              <button
                phx-click="toggle_task_form"
                class="mt-2 text-xs text-indigo-600 hover:underline"
              >
                + Add task
              </button>
            <% end %>
          </div>

          <%!-- Neglect status --%>
          <%= if @neglect_status != :ok do %>
            <div>
              <div class="text-xs text-gray-400 uppercase tracking-wide mb-1">Status</div>
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
        is_internal -> "bg-amber-50 border-amber-200"
        is_operator -> "bg-indigo-50 border-indigo-100"
        true -> "bg-white border-gray-200"
      end

    assigns =
      assigns
      |> assign(:is_operator, is_operator)
      |> assign(:is_internal, is_internal)
      |> assign(:bg_class, bg_class)

    ~H"""
    <div class={"flex #{if @is_operator, do: "justify-end", else: "justify-start"} mb-3"}>
      <div class={"max-w-lg rounded-lg px-4 py-2.5 border #{@bg_class}"}>
        <div class="flex items-center gap-2 mb-1">
          <span class={"text-xs font-medium #{if @is_operator, do: "text-indigo-700", else: "text-gray-700"}"}>
            {sender_name(@message)}
          </span>
          <%= if @is_internal do %>
            <span class="text-xs bg-amber-200 text-amber-800 px-1.5 py-0.5 rounded">
              internal note
            </span>
          <% end %>
          <span class="text-xs text-gray-400">
            {unless @is_internal, do: "via #{@message.source}"}
          </span>
          <span class="text-xs text-gray-400 ml-auto">{format_time(@message.inserted_at)}</span>
        </div>
        <div class="text-sm text-gray-800 whitespace-pre-wrap">{@message.body}</div>
      </div>
    </div>
    """
  end

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

    time_str = Calendar.strftime(datetime, "%I:%M %p")

    cond do
      diff_days == 0 -> time_str
      diff_days == 1 -> "Yesterday #{time_str}"
      diff_days < 7 -> Calendar.strftime(datetime, "%a #{time_str}")
      true -> Calendar.strftime(datetime, "%b %d")
    end
  end

  attr :task, :map, required: true

  defp task_item(assigns) do
    ~H"""
    <div class="group flex items-start gap-2 text-sm p-1 rounded hover:bg-gray-50">
      <button
        phx-click="toggle_task"
        phx-value-id={@task.id}
        class="mt-0.5 flex-shrink-0"
        title="Cycle state: open -> in_progress -> done"
      >
        <.task_status_dot state={@task.state} />
      </button>
      <div class="flex-1 min-w-0">
        <span class={"text-gray-700 #{if @task.state == :done, do: "line-through opacity-50"}"}>
          {@task.title}
        </span>
        <%= if @task.due_at do %>
          <div class="text-xs text-gray-400">
            Due: {format_due_at(@task.due_at)}
          </div>
        <% end %>
      </div>
      <div class="flex items-center gap-1 opacity-0 group-hover:opacity-100 transition-opacity">
        <%= if @task.portal_visible do %>
          <span class="text-xs text-gray-400" title="Visible in portal">
            <.icon name="hero-eye" class="h-3 w-3" />
          </span>
        <% else %>
          <span class="text-xs text-gray-300" title="Hidden from portal">
            <.icon name="hero-eye-slash" class="h-3 w-3" />
          </span>
        <% end %>
        <button
          phx-click="edit_task"
          phx-value-id={@task.id}
          class="text-gray-400 hover:text-indigo-600"
          title="Edit task"
        >
          <.icon name="hero-pencil" class="h-3 w-3" />
        </button>
        <button
          phx-click="delete_task"
          phx-value-id={@task.id}
          data-confirm="Delete this task?"
          class="text-gray-400 hover:text-red-600"
          title="Delete task"
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
      class="p-2 bg-indigo-50 rounded border border-indigo-200 space-y-2"
    >
      <input
        type="text"
        name="title"
        value={@title}
        placeholder="Task title..."
        class="w-full text-xs border border-gray-300 rounded px-2 py-1"
        autofocus
      />
      <input
        type="datetime-local"
        name="due_at"
        value={@due_at}
        class="w-full text-xs border border-gray-300 rounded px-2 py-1"
      />
      <div class="flex items-center gap-2">
        <input
          type="checkbox"
          name="portal_visible"
          value="true"
          checked={@portal_visible}
          id={"edit_task_portal_visible_#{@task.id}"}
          class="h-3 w-3"
        />
        <label for={"edit_task_portal_visible_#{@task.id}"} class="text-xs text-gray-600">
          Visible in portal
        </label>
      </div>
      <div class="flex gap-2">
        <button
          type="submit"
          class="text-xs bg-indigo-600 text-white px-2 py-1 rounded hover:bg-indigo-700"
        >
          Save
        </button>
        <button
          type="button"
          phx-click="cancel_edit_task"
          class="text-xs text-gray-500 hover:text-gray-700"
        >
          Cancel
        </button>
        <button
          type="button"
          phx-click="delete_task"
          phx-value-id={@task.id}
          data-confirm="Delete this task?"
          class="text-xs text-red-500 hover:text-red-700 ml-auto"
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
        :open -> "bg-gray-300"
        _ -> "bg-gray-300"
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <span class={"w-2 h-2 rounded-full #{@color}"} />
    """
  end

  attr :tier, :atom, required: true

  defp tier_badge(assigns) do
    colors =
      case assigns.tier do
        :enterprise -> "text-purple-700 bg-purple-50"
        :standard -> "text-gray-600 bg-gray-50"
        :basic -> "text-gray-400 bg-gray-50"
        _ -> "text-gray-600 bg-gray-50"
      end

    assigns = assign(assigns, :colors, colors)

    ~H"""
    <span class={"text-xs px-1.5 py-0.5 rounded #{@colors}"}>
      {to_string(@tier)}
    </span>
    """
  end

  attr :state, :atom, required: true

  defp state_badge(assigns) do
    colors =
      case assigns.state do
        :new -> "bg-blue-100 text-blue-800"
        :active -> "bg-green-100 text-green-800"
        :waiting -> "bg-yellow-100 text-yellow-800"
        :dormant -> "bg-gray-100 text-gray-600"
        :resolved -> "bg-gray-100 text-gray-400"
        _ -> "bg-gray-100 text-gray-600"
      end

    assigns = assign(assigns, :colors, colors)

    ~H"""
    <span class={"text-xs px-1.5 py-0.5 rounded #{@colors}"}>
      {to_string(@state)}
    </span>
    """
  end

  attr :level, :atom, required: true

  defp neglect_badge(assigns) do
    ~H"""
    <%= case @level do %>
      <% :critical -> %>
        <span class="text-xs px-1.5 py-0.5 rounded border bg-red-100 text-red-800 border-red-300">
          NEGLECTED
        </span>
      <% :warning -> %>
        <span class="text-xs px-1.5 py-0.5 rounded border bg-amber-100 text-amber-800 border-amber-300">
          aging
        </span>
      <% _ -> %>
    <% end %>
    """
  end

  attr :breakdown, :map, required: true

  defp score_breakdown(assigns) do
    entries =
      [
        {"idle", assigns.breakdown.idle},
        {"state", assigns.breakdown.state},
        {"tier", assigns.breakdown.tier},
        {"urgency", assigns.breakdown.urgency},
        {"velocity", assigns.breakdown.velocity},
        {"neglect", assigns.breakdown.neglect_bonus}
      ]
      |> Enum.filter(fn {_, v} -> v > 0 end)

    total = Enum.sum(Enum.map(entries, fn {_, v} -> v end))
    assigns = assign(assigns, :entries, entries) |> assign(:total, total)

    ~H"""
    <div class="p-2 bg-gray-50 rounded text-xs space-y-1">
      <div class="font-medium text-gray-700 mb-1">Score breakdown (total: {@breakdown.total})</div>
      <%= for {key, val} <- @entries do %>
        <div class="flex items-center gap-2">
          <span class="w-20 text-gray-500">{key}</span>
          <div class="flex-1 bg-gray-200 rounded-full h-1.5">
            <div
              class="bg-indigo-400 h-1.5 rounded-full"
              style={"width: #{if @total > 0, do: (val / @total) * 100, else: 0}%"}
            />
          </div>
          <span class="w-6 text-right text-gray-600">{val}</span>
        </div>
      <% end %>
    </div>
    """
  end
end
