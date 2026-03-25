defmodule CustyardWeb.Operator.AttentionQueueLive do
  use CustyardWeb, :live_view

  alias Custyard.{Conversations, Scoring}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Custyard.PubSub, "conversations")
    end

    socket =
      socket
      |> assign(:filter, "all")
      |> assign(:show_score_breakdown, nil)
      |> assign(:show_snooze_menu, nil)
      |> load_conversations()

    {:ok, socket, layout: {CustyardWeb.Layouts, :operator}}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter = params["filter"] || "all"

    socket =
      socket
      |> assign(:filter, filter)
      |> load_conversations()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    {:noreply, push_patch(socket, to: ~p"/operator?filter=#{filter}")}
  end

  def handle_event("toggle_score", %{"id" => id}, socket) do
    id = String.to_integer(id)
    current = socket.assigns.show_score_breakdown

    {:noreply, assign(socket, :show_score_breakdown, if(current == id, do: nil, else: id))}
  end

  def handle_event("toggle_snooze", %{"id" => id}, socket) do
    id = String.to_integer(id)
    current = socket.assigns.show_snooze_menu

    {:noreply, assign(socket, :show_snooze_menu, if(current == id, do: nil, else: id))}
  end

  def handle_event("snooze", %{"id" => id, "duration" => duration}, socket) do
    id = String.to_integer(id)
    conversation = Conversations.get_conversation!(id)

    until = calculate_snooze_until(duration)

    {:ok, _} = Conversations.snooze(conversation, until)

    Phoenix.PubSub.broadcast(Custyard.PubSub, "conversations", {:conversation_updated, id})

    {:noreply, socket |> assign(:show_snooze_menu, nil) |> load_conversations()}
  end

  @impl true
  def handle_info({:conversation_updated, _id}, socket) do
    {:noreply, load_conversations(socket)}
  end

  def handle_info({:conversation_created, _id}, socket) do
    {:noreply, load_conversations(socket)}
  end

  defp load_conversations(socket) do
    filter = socket.assigns.filter

    conversations =
      Conversations.list_for_attention_queue(filter: filter)
      |> Enum.map(fn %{conversation: conv, message_count: message_count} ->
        neglect_status = Scoring.neglect_status(conv)
        breakdown = Scoring.breakdown(conv)
        hours_idle = hours_since(conv.last_operator_action_at || conv.inserted_at)

        %{
          conversation: conv,
          neglect_status: neglect_status,
          breakdown: breakdown,
          hours_idle: hours_idle,
          message_count: message_count
        }
      end)

    assign(socket, :conversations, conversations)
  end

  defp hours_since(nil), do: 0

  defp hours_since(datetime) do
    DateTime.diff(DateTime.utc_now(), datetime, :hour)
  end

  defp calculate_snooze_until(duration) do
    hours =
      case duration do
        "1h" -> 1
        "4h" -> 4
        "1d" -> 24
        "3d" -> 72
        _ -> 1
      end

    DateTime.add(DateTime.utc_now(), hours, :hour)
  end

  # Used in queue_card HEEx template
  @compile {:nowarn_unused_function, format_idle_time: 1}
  defp format_idle_time(hours) when hours < 24, do: "#{hours}h ago"
  defp format_idle_time(hours), do: "#{div(hours, 24)}d ago"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto p-4" data-testid="operator-queue-page">
      <div class="flex items-center justify-between mb-4">
        <h1
          class="text-lg font-semibold text-gray-900 dark:text-zinc-100"
          data-testid="operator-queue-heading"
        >
          What needs attention
        </h1>
        <span class="text-xs text-gray-400 dark:text-zinc-500" data-testid="operator-queue-count">
          {length(@conversations)} items
        </span>
      </div>

      <div class="flex gap-2 mb-4" data-testid="operator-queue-filters">
        <.filter_button filter={@filter} value="all" label="all" />
        <.filter_button filter={@filter} value="new" label="new" />
        <.filter_button filter={@filter} value="active" label="active" />
        <.filter_button filter={@filter} value="waiting" label="waiting" />
        <.filter_button filter={@filter} value="dormant" label="dormant" />
      </div>

      <div class="space-y-2">
        <%= if Enum.empty?(@conversations) do %>
          <div
            class="text-center text-gray-400 dark:text-zinc-500 py-12"
            data-testid="operator-queue-empty"
          >
            Nothing needs attention right now.
          </div>
        <% else %>
          <%= for item <- @conversations do %>
            <.queue_card
              item={item}
              show_score={@show_score_breakdown == item.conversation.id}
              show_snooze={@show_snooze_menu == item.conversation.id}
            />
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  attr :filter, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true

  defp filter_button(assigns) do
    ~H"""
    <button
      phx-click="filter"
      phx-value-filter={@value}
      data-testid={"operator-queue-filter-#{@value}"}
      class={[
        "text-xs px-2.5 py-1 rounded",
        @filter == @value && "bg-indigo-100 text-indigo-700",
        @filter != @value &&
          "bg-gray-100 dark:bg-zinc-800 text-gray-500 dark:text-zinc-400 hover:bg-gray-200 dark:hover:bg-zinc-600"
      ]}
    >
      {@label}
    </button>
    """
  end

  attr :item, :map, required: true
  attr :show_score, :boolean, required: true
  attr :show_snooze, :boolean, required: true

  defp queue_card(assigns) do
    border_color =
      case assigns.item.neglect_status do
        :critical -> "border-l-red-500"
        :warning -> "border-l-amber-400"
        _ -> "border-l-transparent"
      end

    assigns = assign(assigns, :border_color, border_color)

    ~H"""
    <div
      class={"bg-white dark:bg-zinc-800 border border-gray-200 dark:border-zinc-700 rounded-lg p-4 hover:shadow-md transition-shadow border-l-4 #{@border_color}"}
      data-testid={"operator-queue-card-#{@item.conversation.id}"}
    >
      <.link navigate={~p"/operator/conversation/#{@item.conversation.id}"} class="block">
        <div class="flex items-start justify-between mb-1">
          <div class="flex items-center gap-2">
            <span
              class="font-semibold text-gray-900 dark:text-zinc-100"
              data-testid="operator-queue-org-name"
            >
              {@item.conversation.organization.name}
            </span>
            <.tier_badge tier={@item.conversation.organization.tier} />
            <.neglect_badge level={@item.neglect_status} />
          </div>
          <span
            class="text-sm text-gray-400 dark:text-zinc-500"
            data-testid="operator-queue-idle-time"
          >
            {format_idle_time(@item.hours_idle)}
          </span>
        </div>
        <div
          class="text-sm text-gray-500 dark:text-zinc-400 mb-1"
          data-testid="operator-queue-contact"
        >
          {if @item.conversation.contact,
            do: @item.conversation.contact.name || @item.conversation.contact.email,
            else: "Unknown contact"}
        </div>
        <div
          class="text-sm text-gray-800 dark:text-zinc-200 mb-2"
          data-testid="operator-queue-subject"
        >
          {@item.conversation.subject}
        </div>
        <div class="flex items-center gap-2 flex-wrap">
          <.state_badge state={@item.conversation.state} />
          <.urgency_badge urgency={@item.conversation.urgency} />
          <span
            class="text-xs text-gray-400 dark:text-zinc-500 ml-auto"
            data-testid="operator-queue-msg-count"
          >
            {@item.message_count} msg
          </span>
          <span class="text-xs text-gray-400 dark:text-zinc-500" data-testid="operator-queue-score">
            score: {@item.conversation.cached_score}
          </span>
        </div>
      </.link>

      <div class="flex items-center gap-2 mt-3">
        <button
          phx-click="toggle_score"
          phx-value-id={@item.conversation.id}
          class="text-xs text-gray-500 dark:text-zinc-400 hover:text-gray-700 dark:hover:text-zinc-200 px-2 py-1 rounded hover:bg-gray-100 dark:hover:bg-zinc-700"
          data-testid="operator-queue-score-toggle"
        >
          {if @show_score, do: "Hide score", else: "Why this rank?"}
        </button>

        <div class="relative">
          <button
            phx-click="toggle_snooze"
            phx-value-id={@item.conversation.id}
            class="text-xs text-gray-500 dark:text-zinc-400 hover:text-gray-700 dark:hover:text-zinc-200 px-2 py-1 rounded hover:bg-gray-100 dark:hover:bg-zinc-700"
            data-testid="operator-queue-snooze-btn"
          >
            Snooze
          </button>
          <%= if @show_snooze do %>
            <div
              class="absolute top-full left-0 mt-1 bg-white dark:bg-zinc-800 border border-gray-200 dark:border-zinc-700 rounded shadow-lg z-10 p-1"
              data-testid="operator-queue-snooze-menu"
            >
              <%= for opt <- ["1h", "4h", "1d", "3d"] do %>
                <button
                  phx-click="snooze"
                  phx-value-id={@item.conversation.id}
                  phx-value-duration={opt}
                  class="block w-full text-left text-xs px-3 py-1.5 hover:bg-gray-100 dark:hover:bg-zinc-700 rounded"
                  data-testid={"operator-queue-snooze-opt-#{opt}"}
                >
                  {opt}
                </button>
              <% end %>
            </div>
          <% end %>
        </div>
      </div>

      <%= if @show_score do %>
        <.score_breakdown breakdown={@item.breakdown} />
      <% end %>
    </div>
    """
  end

  attr :tier, :atom, required: true

  defp tier_badge(assigns) do
    colors =
      case assigns.tier do
        :enterprise -> "text-purple-700 bg-purple-50"
        :standard -> "text-gray-600 dark:text-zinc-400 bg-gray-50 dark:bg-zinc-800"
        :basic -> "text-gray-400 dark:text-zinc-500 bg-gray-50 dark:bg-zinc-800"
        _ -> "text-gray-600 dark:text-zinc-400 bg-gray-50 dark:bg-zinc-800"
      end

    assigns = assign(assigns, :colors, colors)

    ~H"""
    <span
      class={"text-xs px-1.5 py-0.5 rounded #{@colors}"}
      data-testid={"operator-tier-badge-#{@tier}"}
    >
      {to_string(@tier)}
    </span>
    """
  end

  attr :level, :atom, required: true

  defp neglect_badge(assigns) do
    ~H"""
    <%= case @level do %>
      <% :critical -> %>
        <span
          class="text-xs px-1.5 py-0.5 rounded border bg-red-100 text-red-800 border-red-300"
          data-testid="operator-neglect-badge-critical"
        >
          NEGLECTED
        </span>
      <% :warning -> %>
        <span
          class="text-xs px-1.5 py-0.5 rounded border bg-amber-100 text-amber-800 border-amber-300"
          data-testid="operator-neglect-badge-warning"
        >
          aging
        </span>
      <% _ -> %>
    <% end %>
    """
  end

  attr :state, :atom, required: true

  defp state_badge(assigns) do
    colors =
      case assigns.state do
        :new -> "bg-blue-100 text-blue-800"
        :active -> "bg-green-100 text-green-800"
        :waiting -> "bg-yellow-100 text-yellow-800"
        :dormant -> "bg-gray-100 dark:bg-zinc-700 text-gray-600 dark:text-zinc-400"
        :resolved -> "bg-gray-100 dark:bg-zinc-700 text-gray-400 dark:text-zinc-500"
        _ -> "bg-gray-100 dark:bg-zinc-700 text-gray-600 dark:text-zinc-400"
      end

    assigns = assign(assigns, :colors, colors)

    ~H"""
    <span
      class={"text-xs px-1.5 py-0.5 rounded #{@colors}"}
      data-testid={"operator-state-badge-#{@state}"}
    >
      {to_string(@state)}
    </span>
    """
  end

  attr :urgency, :atom, required: true

  defp urgency_badge(assigns) do
    ~H"""
    <%= case @urgency do %>
      <% :urgent -> %>
        <span
          class="text-xs px-1.5 py-0.5 rounded font-medium bg-red-100 text-red-800"
          data-testid="operator-urgency-badge-urgent"
        >
          urgent
        </span>
      <% :elevated -> %>
        <span
          class="text-xs px-1.5 py-0.5 rounded font-medium bg-orange-100 text-orange-800"
          data-testid="operator-urgency-badge-elevated"
        >
          elevated
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
    <div
      class="mt-2 p-2 bg-gray-50 dark:bg-zinc-800 rounded text-xs space-y-1"
      data-testid="operator-score-breakdown"
    >
      <div class="font-medium text-gray-700 dark:text-zinc-300 mb-1">Score breakdown</div>
      <%= for {key, val} <- @entries do %>
        <div class="flex items-center gap-2">
          <span class="w-20 text-gray-500 dark:text-zinc-400">{key}</span>
          <div class="flex-1 bg-gray-200 dark:bg-zinc-600 rounded-full h-1.5">
            <div
              class="bg-indigo-400 h-1.5 rounded-full"
              style={"width: #{if @total > 0, do: (val / @total) * 100, else: 0}%"}
            />
          </div>
          <span class="w-6 text-right text-gray-600 dark:text-zinc-400">{val}</span>
        </div>
      <% end %>
    </div>
    """
  end
end
