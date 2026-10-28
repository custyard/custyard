defmodule CustyardWeb.Staff.AttentionQueueLive do
  use CustyardWeb, :live_view

  import CustyardWeb.StaffComponents

  alias Custyard.{Conversations, EmailSetup, Labels, Scoring}

  # Debounce delay for PubSub-triggered reloads (milliseconds)
  # This prevents N+1 query storms when multiple conversations update rapidly
  @reload_debounce_ms 500

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Custyard.PubSub, "conversations")
      Process.send_after(self(), :refresh_deadlines, 60_000)
    end

    socket =
      socket
      |> assign(:page_title, "Attention Queue")
      |> assign(:filter, "all")
      |> assign(:label_id, nil)
      |> assign(
        :labels,
        Labels.list(socket.assigns.current_scope)
      )
      |> assign(:show_score_breakdown, nil)
      |> assign(:show_snooze_menu, nil)
      |> assign(:reload_timer, nil)
      |> load_conversations()

    {:ok, socket, layout: {CustyardWeb.Layouts, :staff}}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filter = params["filter"] || "all"

    labels =
      Labels.list(socket.assigns.current_scope)

    label = Enum.find(labels, &(to_string(&1.id) == params["label"]))

    socket =
      socket
      |> assign(:filter, filter)
      |> assign(:labels, labels)
      |> assign(:label_id, label && label.id)
      |> load_conversations()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    {:noreply,
     push_patch(socket, to: ~p"/app?#{[filter: filter, label: socket.assigns.label_id]}")}
  end

  def handle_event("filter_label", %{"label" => label}, socket) do
    {:noreply, push_patch(socket, to: ~p"/app?#{[filter: socket.assigns.filter, label: label]}")}
  end

  def handle_event("toggle_score", %{"id" => id}, socket) do
    case Integer.parse(id) do
      {id, ""} ->
        current = socket.assigns.show_score_breakdown
        {:noreply, assign(socket, :show_score_breakdown, if(current == id, do: nil, else: id))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("toggle_snooze", %{"id" => id}, socket) do
    case Integer.parse(id) do
      {id, ""} ->
        current = socket.assigns.show_snooze_menu
        {:noreply, assign(socket, :show_snooze_menu, if(current == id, do: nil, else: id))}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("snooze", %{"id" => id, "duration" => duration}, socket) do
    with {id, ""} <- Integer.parse(id),
         true <- queue_contains_conversation?(socket, id) do
      until = calculate_snooze_until(duration)

      case Conversations.with_access(socket.assigns.current_scope, id, fn current, _staff ->
             Conversations.snooze(current, until)
           end) do
        {:ok, conversation} ->
          Phoenix.PubSub.broadcast(Custyard.PubSub, "conversations", {:conversation_updated, id})

          Conversations.broadcast_to_org(
            conversation.organization_id,
            {:conversation_updated, id}
          )

          {:noreply, socket |> assign(:show_snooze_menu, nil) |> load_conversations()}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to snooze conversation")}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("unsnooze", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(id),
         true <- queue_contains_conversation?(socket, id) do
      case Conversations.with_access(socket.assigns.current_scope, id, fn current, _staff ->
             Conversations.unsnooze(current)
           end) do
        {:ok, conversation} ->
          Phoenix.PubSub.broadcast(Custyard.PubSub, "conversations", {:conversation_updated, id})

          Conversations.broadcast_to_org(
            conversation.organization_id,
            {:conversation_updated, id}
          )

          {:noreply, load_conversations(socket)}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to un-snooze conversation")}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:conversation_updated, _id}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info({:conversation_created, _id}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  # Debounced reload timer fired - perform the actual reload
  def handle_info(:debounced_reload, socket) do
    {:noreply,
     socket
     |> assign(:reload_timer, nil)
     |> load_conversations()}
  end

  def handle_info(:refresh_deadlines, socket) do
    Process.send_after(self(), :refresh_deadlines, 60_000)
    {:noreply, load_conversations(socket)}
  end

  # Catch-all for unexpected PubSub messages to prevent LiveView crashes
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Schedule a debounced reload - cancel any pending timer first
  defp schedule_reload(socket) do
    # Cancel existing timer if any
    if timer = socket.assigns[:reload_timer] do
      Process.cancel_timer(timer)
    end

    # Schedule new reload
    timer = Process.send_after(self(), :debounced_reload, @reload_debounce_ms)
    assign(socket, :reload_timer, timer)
  end

  defp load_conversations(socket) do
    filter = socket.assigns.filter
    now = DateTime.utc_now()

    # Read staff settings once for the whole render. Without this each
    # row re-reads them (four uncached Repo.one calls) and re-counts its own
    # 24h messages, which is a remote round trip each in production.
    settings = Scoring.preload_settings(socket.assigns.current_tenant.id)

    conversations =
      Conversations.list(socket.assigns.current_scope,
        filter: filter,
        label_id: socket.assigns.label_id
      )

    labels_by_conversation = Labels.for_conversations(Enum.map(conversations, & &1.conversation))

    conversations =
      Enum.map(conversations, fn %{conversation: conv, message_count: message_count} = item ->
        neglect_status = Scoring.neglect_status(conv, settings.thresholds)

        breakdown =
          Scoring.breakdown(conv, settings: settings, message_count: message_count)

        hours_idle = hours_since(conv.last_staff_action_at || conv.inserted_at)
        is_snoozed = conv.snoozed_until && DateTime.compare(conv.snoozed_until, now) == :gt

        %{
          conversation: conv,
          neglect_status: neglect_status,
          breakdown: breakdown,
          hours_idle: hours_idle,
          message_count: message_count,
          due_task_count: item.due_task_count,
          labels: Map.get(labels_by_conversation, conv.id, []),
          is_snoozed: is_snoozed,
          # Derived from preloaded contact/prospect — no extra queries
          reply_channel: Conversations.reply_channel(conv)
        }
      end)

    socket
    |> assign(:conversations, conversations)
    |> assign(:email_setup, EmailSetup.summary(socket.assigns.current_tenant.id))
    |> assign(
      :can_setup_email,
      EmailSetup.authorized?(socket.assigns.current_staff, socket.assigns.current_tenant.id)
    )
    |> assign(
      :labels,
      Labels.list(socket.assigns.current_scope)
    )
  end

  defp queue_contains_conversation?(socket, id) do
    Enum.any?(socket.assigns.conversations, fn item -> item.conversation.id == id end)
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

  # Format snooze expiry time for display
  @compile {:nowarn_unused_function, format_snooze_time: 1}
  defp format_snooze_time(datetime) do
    Calendar.strftime(datetime, "%b %d %H:%M")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto p-4" data-testid="staff-queue-page">
      <section
        :if={@can_setup_email and not @email_setup.complete?}
        class="mb-5 rounded-lg border border-indigo-200 dark:border-indigo-800 bg-white dark:bg-zinc-800 p-4"
        data-testid="email-setup-prompt"
      >
        <h2 class="text-sm font-semibold text-gray-900 dark:text-zinc-100">
          {if @email_setup.configured?, do: "Finish email setup", else: "Connect support email"}
        </h2>
        <p class="mt-1 text-sm text-gray-600 dark:text-zinc-300">
          Forward your support mailbox, verify the sending address and test a reply.
        </p>
        <.link
          navigate={~p"/app/settings/email"}
          class="mt-2 inline-block text-sm font-medium text-indigo-600 dark:text-indigo-300"
        >{if @email_setup.configured?, do: "Continue setup", else: "Set up email"}</.link>
      </section>
      <div class="flex items-center justify-between mb-4">
        <h1
          class="text-lg font-semibold text-gray-900 dark:text-zinc-100"
          data-testid="staff-queue-heading"
        >
          What needs attention
        </h1>
        <span class="text-xs text-gray-400 dark:text-zinc-500" data-testid="staff-queue-count">
          {length(@conversations)} {if length(@conversations) == 1, do: "item", else: "items"}
        </span>
      </div>

      <div
        class="flex flex-wrap gap-2 mb-4"
        role="group"
        aria-label="Filter by status"
        data-testid="staff-queue-filters"
      >
        <.filter_button filter={@filter} value="all" label="all" />
        <.filter_button filter={@filter} value="new" label="new" />
        <.filter_button filter={@filter} value="active" label="active" />
        <.filter_button filter={@filter} value="waiting" label="waiting" />
        <.filter_button filter={@filter} value="dormant" label="dormant" />
        <.filter_button filter={@filter} value="snoozed" label="snoozed" />
        <.filter_button filter={@filter} value="due_tasks" label="tasks due" />
      </div>

      <form
        :if={@labels != []}
        id="queue-label-filter"
        phx-change="filter_label"
        class="mb-4 flex items-center gap-2 text-sm"
      >
        <label for="queue-label">Label</label>
        <select id="queue-label" name="label" class="rounded text-sm dark:bg-zinc-800">
          <option value="">All labels</option>
          <option :for={label <- @labels} value={label.id} selected={@label_id == label.id}>
            {label.name}
          </option>
        </select>
      </form>

      <div class="space-y-2">
        <%= if Enum.empty?(@conversations) do %>
          <div
            class="text-center text-gray-400 dark:text-zinc-500 py-12"
            data-testid="staff-queue-empty"
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
      aria-pressed={to_string(@filter == @value)}
      data-testid={"staff-queue-filter-#{@value}"}
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
      data-testid={"staff-queue-card-#{@item.conversation.id}"}
    >
      <.link navigate={~p"/app/threads/#{@item.conversation.id}"} class="block">
        <div class="flex items-start justify-between mb-1">
          <div class="flex items-center gap-2">
            <span
              class="font-semibold text-gray-900 dark:text-zinc-100"
              data-testid="staff-queue-org-name"
            >
              {if @item.conversation.organization,
                do: @item.conversation.organization.name,
                else: "Unlinked prospect"}
            </span>
            <.tier_badge
              :if={@item.conversation.organization}
              tier={@item.conversation.organization.tier}
            />
            <.neglect_badge level={@item.neglect_status} />
          </div>
          <span
            class="text-sm text-gray-400 dark:text-zinc-500"
            data-testid="staff-queue-idle-time"
          >
            {format_idle_time(@item.hours_idle)}
          </span>
        </div>
        <div
          class="text-sm text-gray-500 dark:text-zinc-400 mb-1"
          data-testid="staff-queue-contact"
        >
          {if @item.conversation.contact,
            do: @item.conversation.contact.name || @item.conversation.contact.email,
            else: "Unknown contact"}
        </div>
        <div
          class="text-sm text-gray-800 dark:text-zinc-200 mb-2"
          data-testid="staff-queue-subject"
        >
          {@item.conversation.subject}
        </div>
        <div class="flex items-center gap-2 flex-wrap">
          <.state_badge state={@item.conversation.state} />
          <.urgency_badge urgency={@item.conversation.urgency} />
          <.source_badge source={@item.conversation.source} />
          <span
            :if={@item.due_task_count > 0}
            class="text-xs rounded px-2 py-0.5 bg-amber-100 dark:bg-amber-950 text-amber-800 dark:text-amber-300"
            data-testid="queue-tasks-due"
            title="Complete or reschedule the task to clear this reminder. Conversation snoozing does not change its deadline."
          >
            {@item.due_task_count} {if @item.due_task_count == 1, do: "task due", else: "tasks due"}
          </span>
          <span
            :for={label <- @item.labels}
            class="text-xs rounded px-2 py-0.5 bg-indigo-50 dark:bg-indigo-950 text-indigo-700 dark:text-indigo-300"
            data-testid={"queue-label-#{label.id}"}
          >{label.name}</span>
          <%!-- Channel the mail arrived on (spec-inbound-channels, "Attention
               queue"): the public address, never the ingress address. --%>
          <span
            :if={@item.conversation.inbound_channel}
            class="text-xs px-1.5 py-0.5 rounded bg-teal-50 dark:bg-teal-950 text-teal-700 dark:text-teal-300 truncate max-w-[12rem]"
            title={"Channel #{@item.conversation.inbound_channel.public_address}"}
            data-testid="staff-queue-channel"
          >
            {@item.conversation.inbound_channel.public_address}
          </span>
          <span
            :if={@item.conversation.suspect}
            class="text-xs px-1.5 py-0.5 rounded bg-amber-100 dark:bg-amber-950 text-amber-800 dark:text-amber-300"
            title="Triage flagged this conversation as suspect"
            data-testid="staff-queue-suspect"
          >
            suspect
          </span>
          <span
            :if={@item.conversation.language}
            class="text-xs px-1.5 py-0.5 rounded bg-gray-100 dark:bg-zinc-700 text-gray-600 dark:text-zinc-300 uppercase"
            title={"Detected language: #{Custyard.Email.LanguageDetector.name(@item.conversation.language)}"}
            data-testid="staff-queue-language"
          >
            {@item.conversation.language}
          </span>
          <.intake_source_tag
            :if={@item.conversation.intake_source_key}
            source_key={@item.conversation.intake_source_key}
          />
          <%!-- Flag only public-intake conversations: email/portal conversations
               derive their reply channel elsewhere. A badge, never a filter. --%>
          <.no_reply_channel_badge :if={
            @item.conversation.source == :public_intake and @item.reply_channel == :none
          } />
          <span
            class="text-xs text-gray-400 dark:text-zinc-500 ml-auto"
            data-testid="staff-queue-msg-count"
          >
            {@item.message_count} msg
          </span>
          <span class="text-xs text-gray-400 dark:text-zinc-500" data-testid="staff-queue-score">
            score: {@item.conversation.cached_score}
          </span>
        </div>
      </.link>

      <div class="flex items-center gap-2 mt-3">
        <button
          phx-click="toggle_score"
          phx-value-id={@item.conversation.id}
          class="text-xs text-gray-500 dark:text-zinc-400 hover:text-gray-700 dark:hover:text-zinc-200 px-2 py-1 rounded hover:bg-gray-100 dark:hover:bg-zinc-700"
          data-testid="staff-queue-score-toggle"
        >
          {if @show_score, do: "Hide score", else: "Why this rank?"}
        </button>

        <%= if @item.is_snoozed do %>
          <button
            phx-click="unsnooze"
            phx-value-id={@item.conversation.id}
            class="text-xs text-indigo-600 dark:text-indigo-400 hover:text-indigo-800 dark:hover:text-indigo-200 px-2 py-1 rounded hover:bg-indigo-50 dark:hover:bg-indigo-900/30"
            data-testid="staff-queue-unsnooze-btn"
          >
            Un-snooze
          </button>
          <span class="text-xs text-gray-400 dark:text-zinc-500">
            until {format_snooze_time(@item.conversation.snoozed_until)}
          </span>
        <% else %>
          <div class="relative">
            <button
              phx-click="toggle_snooze"
              phx-value-id={@item.conversation.id}
              aria-haspopup="menu"
              aria-expanded={to_string(@show_snooze)}
              class="text-xs text-gray-500 dark:text-zinc-400 hover:text-gray-700 dark:hover:text-zinc-200 px-2 py-1 rounded hover:bg-gray-100 dark:hover:bg-zinc-700"
              data-testid="staff-queue-snooze-btn"
            >
              Snooze
            </button>
            <%= if @show_snooze do %>
              <div
                phx-click-away="toggle_snooze"
                phx-key="escape"
                phx-keydown="toggle_snooze"
                phx-value-id={@item.conversation.id}
                role="menu"
                aria-label="Snooze duration options"
                class="absolute top-full left-0 mt-1 bg-white dark:bg-zinc-800 border border-gray-200 dark:border-zinc-700 rounded shadow-lg z-10 p-1"
                data-testid="staff-queue-snooze-menu"
              >
                <%= for opt <- ["1h", "4h", "1d", "3d"] do %>
                  <button
                    phx-click="snooze"
                    phx-value-id={@item.conversation.id}
                    phx-value-duration={opt}
                    role="menuitem"
                    class="block w-full text-left text-xs px-3 py-1.5 hover:bg-gray-100 dark:hover:bg-zinc-700 rounded focus:outline-none focus:bg-gray-100 dark:focus:bg-zinc-700"
                    data-testid={"staff-queue-snooze-opt-#{opt}"}
                  >
                    {opt}
                  </button>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>
      </div>

      <%= if @show_score do %>
        <.score_breakdown breakdown={@item.breakdown} show_total={false} />
      <% end %>
    </div>
    """
  end
end
