defmodule CustyardWeb.Operator.ConversationLive do
  use CustyardWeb, :live_view

  alias Custyard.{Repo, Conversation, Message, Task, Scoring}
  import Ecto.Query

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
        now = DateTime.utc_now()

        {:ok, updated} =
          conversation
          |> Ecto.Changeset.change(state: :active, last_operator_action_at: now)
          |> Repo.update()

        Scoring.calculate_and_cache(updated.id)
        Phoenix.PubSub.broadcast(Custyard.PubSub, "conversations", {:conversation_updated, updated.id})
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
      |> assign(:show_task_form, false)

    {:ok, socket, layout: {CustyardWeb.Layouts, :operator}}
  end

  @impl true
  def handle_event("send_reply", %{"body" => body}, socket) when byte_size(body) > 0 do
    conversation = socket.assigns.conversation

    {:ok, _message} =
      %Message{}
      |> Message.changeset(%{
        source: :operator,
        body: body,
        is_internal_note: false,
        conversation_id: conversation.id
      })
      |> Repo.insert()

    # Update last_operator_action_at and ensure state is active
    now = DateTime.utc_now()

    {:ok, _} =
      conversation
      |> Ecto.Changeset.change(last_operator_action_at: now, state: :active)
      |> Repo.update()

    Scoring.calculate_and_cache(conversation.id)
    Phoenix.PubSub.broadcast(Custyard.PubSub, "conversation:#{conversation.id}", :message_added)
    Phoenix.PubSub.broadcast(Custyard.PubSub, "conversations", {:conversation_updated, conversation.id})

    {:noreply, socket |> assign(:reply_text, "") |> reload_conversation()}
  end

  def handle_event("send_reply", _params, socket), do: {:noreply, socket}

  def handle_event("add_note", %{"body" => body}, socket) when byte_size(body) > 0 do
    conversation = socket.assigns.conversation

    {:ok, _message} =
      %Message{}
      |> Message.changeset(%{
        source: :operator,
        body: body,
        is_internal_note: true,
        conversation_id: conversation.id
      })
      |> Repo.insert()

    Phoenix.PubSub.broadcast(Custyard.PubSub, "conversation:#{conversation.id}", :message_added)

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
    now = DateTime.utc_now()

    {:ok, _} =
      conversation
      |> Ecto.Changeset.change(state: new_state, last_operator_action_at: now)
      |> Repo.update()

    Scoring.calculate_and_cache(conversation.id)
    Phoenix.PubSub.broadcast(Custyard.PubSub, "conversations", {:conversation_updated, conversation.id})

    {:noreply, reload_conversation(socket)}
  end

  def handle_event("toggle_task_form", _params, socket) do
    {:noreply, assign(socket, :show_task_form, !socket.assigns.show_task_form)}
  end

  def handle_event("update_task_title", %{"title" => title}, socket) do
    {:noreply, assign(socket, :new_task_title, title)}
  end

  def handle_event("add_task", %{"title" => title}, socket) when byte_size(title) > 0 do
    conversation = socket.assigns.conversation

    {:ok, _task} =
      %Task{}
      |> Task.changeset(%{
        title: title,
        conversation_id: conversation.id
      })
      |> Repo.insert()

    {:noreply,
     socket
     |> assign(:new_task_title, "")
     |> assign(:show_task_form, false)
     |> reload_conversation()}
  end

  def handle_event("add_task", _params, socket), do: {:noreply, socket}

  def handle_event("toggle_task", %{"id" => id}, socket) do
    task = Repo.get!(Task, id)

    new_state =
      case task.state do
        :open -> :in_progress
        :in_progress -> :done
        :done -> :open
      end

    {:ok, _} = task |> Task.state_changeset(new_state) |> Repo.update()

    {:noreply, reload_conversation(socket)}
  end

  @impl true
  def handle_info(:message_added, socket) do
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
    Repo.get!(Conversation, id)
    |> Repo.preload([:organization, :contact, :tasks, messages: from(m in Message, order_by: m.inserted_at)])
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
              {if @conversation.contact, do: @conversation.contact.name || @conversation.contact.email, else: "Unknown"}
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
              <div class="space-y-1">
                <%= for task <- @conversation.tasks do %>
                  <div class="flex items-start gap-2 text-sm">
                    <button
                      phx-click="toggle_task"
                      phx-value-id={task.id}
                      class="mt-0.5 flex-shrink-0"
                    >
                      <.task_status_dot state={task.state} />
                    </button>
                    <span class={"text-gray-700 #{if task.state == :done, do: "line-through opacity-50"}"}>{task.title}</span>
                    <%= if task.portal_visible do %>
                      <span class="text-xs text-gray-400 ml-auto" title="Visible in portal">
                        <.icon name="hero-eye" class="h-3 w-3" />
                      </span>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>

            <%= if @show_task_form do %>
              <form phx-submit="add_task" class="mt-2">
                <input
                  type="text"
                  name="title"
                  value={@new_task_title}
                  phx-change="update_task_title"
                  placeholder="Task title..."
                  class="w-full text-xs border border-gray-300 rounded px-2 py-1"
                  autofocus
                />
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
            <span class="text-xs bg-amber-200 text-amber-800 px-1.5 py-0.5 rounded">internal note</span>
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
    now = DateTime.utc_now()
    diff_days = Date.diff(DateTime.to_date(now), DateTime.to_date(datetime))

    time_str = Calendar.strftime(datetime, "%I:%M %p")

    cond do
      diff_days == 0 -> time_str
      diff_days == 1 -> "Yesterday #{time_str}"
      diff_days < 7 -> Calendar.strftime(datetime, "%a #{time_str}")
      true -> Calendar.strftime(datetime, "%b %d")
    end
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
