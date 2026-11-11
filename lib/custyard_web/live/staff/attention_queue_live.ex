defmodule CustyardWeb.Staff.AttentionQueueLive do
  use CustyardWeb, :live_view

  import CustyardWeb.StaffComponents

  alias Custyard.{Threads, EmailSetup, Labels, Scoring}
  alias Custyard.Threads.QueuePreview

  # Debounce delay for PubSub-triggered reloads (milliseconds)
  # This prevents N+1 query storms when multiple threads update rapidly
  @reload_debounce_ms 500

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Custyard.PubSub, "threads")
      Phoenix.PubSub.subscribe(Custyard.PubSub, "email_setup:#{socket.assigns.current_tenant.id}")
      Process.send_after(self(), :refresh_deadlines, 60_000)
    end

    # The queue itself is loaded by handle_params/3, which always runs after
    # mount and before the first render; loading here as well ran every query
    # twice per page view.
    socket =
      socket
      |> assign(:page_title, "Attention Queue")
      |> assign(:show_score_breakdown, nil)
      |> assign(:show_snooze_menu, nil)
      |> assign(:reload_timer, nil)

    {:ok, socket, layout: {CustyardWeb.Layouts, :staff}}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    labels = Labels.list(socket.assigns.current_scope)
    label = Enum.find(labels, &(to_string(&1.id) == params["label"]))

    socket =
      socket
      |> assign(:filter, params["filter"] || "all")
      |> assign(:labels, labels)
      |> assign(:label_id, label && label.id)
      # The conversation the staff member came back from, so the keyboard
      # selection resumes there (see the QueueKeys hook).
      |> assign(:selected_id, positive_integer(params["at"]))
      |> load_threads()

    {:noreply, socket}
  end

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _ -> nil
    end
  end

  defp positive_integer(_value), do: nil

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

  # Click outside the open menu, or Escape.
  def handle_event("close_snooze", _params, socket) do
    {:noreply, assign(socket, :show_snooze_menu, nil)}
  end

  def handle_event("snooze", %{"id" => id, "duration" => duration}, socket) do
    with {id, ""} <- Integer.parse(id),
         true <- queue_contains_thread?(socket, id) do
      until = calculate_snooze_until(duration)

      case Threads.with_access(socket.assigns.current_scope, id, fn current, _staff ->
             Threads.snooze(current, until)
           end) do
        {:ok, thread} ->
          Phoenix.PubSub.broadcast(Custyard.PubSub, "threads", {:thread_updated, id})

          Threads.broadcast_to_org(
            thread.organization_id,
            {:thread_updated, id}
          )

          {:noreply, socket |> assign(:show_snooze_menu, nil) |> reload_queue()}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to snooze thread")}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("unsnooze", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(id),
         true <- queue_contains_thread?(socket, id) do
      case Threads.with_access(socket.assigns.current_scope, id, fn current, _staff ->
             Threads.unsnooze(current)
           end) do
        {:ok, thread} ->
          Phoenix.PubSub.broadcast(Custyard.PubSub, "threads", {:thread_updated, id})

          Threads.broadcast_to_org(
            thread.organization_id,
            {:thread_updated, id}
          )

          {:noreply, reload_queue(socket)}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to un-snooze thread")}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  @impl true
  def handle_info(:email_setup_updated, socket) do
    {:noreply, assign(socket, :email_setup, EmailSetup.summary(socket.assigns.current_tenant.id))}
  end

  def handle_info({:thread_updated, _id}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  def handle_info({:thread_created, _id}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  # Debounced reload timer fired - perform the actual reload
  def handle_info(:debounced_reload, socket) do
    {:noreply,
     socket
     |> assign(:reload_timer, nil)
     |> reload_queue()}
  end

  def handle_info(:refresh_deadlines, socket) do
    Process.send_after(self(), :refresh_deadlines, 60_000)
    {:noreply, reload_queue(socket)}
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

  # Refresh after a change: labels may have been added since the page loaded.
  defp reload_queue(socket) do
    socket
    |> assign(:labels, Labels.list(socket.assigns.current_scope))
    |> load_threads()
  end

  defp load_threads(socket) do
    filter = socket.assigns.filter
    now = DateTime.utc_now()

    # Read staff settings once for the whole render. Without this each
    # row re-reads them (four uncached Repo.one calls) and re-counts its own
    # 24h messages, which is a remote round trip each in production.
    settings = Scoring.preload_settings(socket.assigns.current_tenant.id)

    scope = socket.assigns.current_scope
    threads = Threads.list(scope, filter: filter, label_id: socket.assigns.label_id)

    labels_by_thread = Labels.for_threads(Enum.map(threads, & &1.thread))
    # Snippet and last speaker for every row in one query (no per-row lookups).
    previews = Threads.queue_previews(scope, Enum.map(threads, & &1.thread.id))

    threads =
      Enum.map(threads, fn %{thread: conv, message_count: message_count} = item ->
        neglect_status = Scoring.neglect_status(conv, settings.thresholds)

        breakdown =
          Scoring.breakdown(conv, settings: settings, message_count: message_count)

        hours_idle = hours_since(conv.last_staff_action_at || conv.inserted_at)

        is_snoozed =
          not is_nil(conv.snoozed_until) and DateTime.compare(conv.snoozed_until, now) == :gt

        preview = Map.get(previews, conv.id)

        %{
          thread: conv,
          neglect_status: neglect_status,
          breakdown: breakdown,
          hours_idle: hours_idle,
          message_count: message_count,
          exchange_count: item.exchange_count,
          due_task_count: item.due_task_count,
          labels: Map.get(labels_by_thread, conv.id, []),
          is_snoozed: is_snoozed,
          # Derived from preloaded contact/prospect — no extra queries
          reply_channel: Threads.reply_channel(conv),
          preview: preview,
          turn: QueuePreview.turn(conv, preview),
          last_exchange_at: (preview && preview.last_spoke_at) || conv.inserted_at
        }
      end)

    socket
    |> assign(:threads, threads)
    |> assign(:filter_counts, Threads.queue_counts(scope, label_id: socket.assigns.label_id))
    |> assign(:email_setup, EmailSetup.summary(socket.assigns.current_tenant.id))
    |> assign(
      :can_setup_email,
      EmailSetup.authorized?(socket.assigns.current_staff, socket.assigns.current_tenant.id)
    )
  end

  defp queue_contains_thread?(socket, id) do
    Enum.any?(socket.assigns.threads, fn item -> item.thread.id == id end)
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

  defp format_idle_time(hours) when hours < 24, do: "#{hours}h"
  defp format_idle_time(hours), do: "#{div(hours, 24)}d"

  # Format snooze expiry time for display
  defp format_snooze_time(datetime) do
    Calendar.strftime(datetime, "%b %d %H:%M")
  end

  # The contact is who staff are talking to. The customer is added only when
  # it says something the contact line does not already say.
  defp who(%{contact: %{name: name}}) when is_binary(name) and name != "", do: name
  defp who(%{contact: %{email: email}}) when is_binary(email) and email != "", do: email
  defp who(%{organization: %{name: name}}), do: name
  defp who(_thread), do: "Unlinked prospect"

  defp customer_line(%{organization: nil} = thread) do
    if who(thread) == "Unlinked prospect", do: nil, else: "Unlinked prospect"
  end

  defp customer_line(%{organization: org} = thread) do
    shown = thread |> who() |> String.downcase()
    name = String.downcase(org.name)

    if shown == name or String.ends_with?(shown, "@" <> name), do: nil, else: org.name
  end

  defp messages_summary(%{exchange_count: exchanged, message_count: total})
       when total > exchanged,
       do: "#{exchanged} exchanged with the customer, #{total - exchanged} internal or automatic"

  defp messages_summary(%{exchange_count: exchanged}),
    do: "#{exchanged} exchanged with the customer"

  # A row's link carries the queue it was opened from (filter, label and the
  # row's position), so the conversation can offer previous and next in the
  # same order.
  defp thread_path(thread_id, filter, label_id, pos) do
    params =
      Enum.reject(
        [filter: if(filter != "all", do: filter), label: label_id, pos: pos],
        fn {_key, value} -> is_nil(value) end
      )

    ~p"/app/threads/#{thread_id}?#{params}"
  end

  # "billing@onetimesecret.com" -> "billing@"; the full address stays in the title.
  defp mailbox_local(address) do
    case String.split(address, "@", parts: 2) do
      [local, _domain] -> local <> "@"
      _ -> address
    end
  end

  defp snippet_prefix(%{snippet_from: :staff, author_staff_id: id}, id) when is_integer(id),
    do: "You:"

  defp snippet_prefix(%{snippet_from: :staff}, _staff_id), do: "Staff:"
  defp snippet_prefix(%{snippet_from: :note}, _staff_id), do: "Note:"
  defp snippet_prefix(%{snippet_from: :auto_reply}, _staff_id), do: "Auto-reply:"
  defp snippet_prefix(_preview, _staff_id), do: nil

  defp turn_label(:ours), do: "Needs reply"
  defp turn_label(:theirs), do: "Waiting on customer"
  defp turn_label(:none), do: nil

  defp turn_title(%{turn: :ours, preview: %{last_speaker: :customer}}),
    do: "The customer spoke last. A reply is needed."

  defp turn_title(%{turn: :ours}), do: "Nobody has replied to the customer yet."

  defp turn_title(%{turn: :theirs, thread: %{state: :waiting}}),
    do: "Marked as waiting on the customer."

  defp turn_title(%{turn: :theirs}), do: "Staff replied last. The customer acts next."
  defp turn_title(_item), do: nil

  # What the right-aligned age measures, spelled out for the hover title and
  # for screen readers. Neglect is counted from the last staff action, which
  # can be older than the last message, so it is stated separately.
  defp age_title(item) do
    at = format_timestamp(item.last_exchange_at)

    spoke =
      case item.preview && item.preview.last_speaker do
        :customer -> "Customer wrote last, #{at}"
        :staff -> "Staff replied last, #{at}"
        _ -> "Opened #{at}, no messages exchanged yet"
      end

    case item.neglect_status do
      :critical -> "#{spoke}. Neglected: no staff action for #{format_idle_time(item.hours_idle)}"
      :warning -> "#{spoke}. Aging: no staff action for #{format_idle_time(item.hours_idle)}"
      _ -> spoke
    end
  end

  @filters [
    {"all", "all"},
    {"needs_reply", "needs reply"},
    {"new", "new"},
    {"active", "active"},
    {"waiting", "waiting"},
    {"dormant", "dormant"},
    {"snoozed", "snoozed"},
    {"due_tasks", "tasks due"}
  ]

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :filters, @filters)

    ~H"""
    <div class="mx-auto w-full max-w-6xl px-3 py-4 sm:px-4" data-testid="staff-queue-page">
      <section
        :if={@can_setup_email and not @email_setup.complete?}
        class="mb-5 rounded-lg border border-indigo-200 dark:border-indigo-800 bg-white dark:bg-zinc-800 p-4"
        data-testid="email-setup-prompt"
      >
        <h2 class="text-sm font-semibold text-gray-900 dark:text-zinc-100">
          {if @email_setup.configured?, do: "Finish email setup", else: "Connect support email"}
        </h2>
        <p :if={not @email_setup.configured?} class="mt-1 text-sm text-gray-600 dark:text-zinc-300">
          Forward your support mailbox, verify the sending address and test a reply.
        </p>
        <div :if={@email_setup.configured?} class="mt-1 text-sm text-gray-600 dark:text-zinc-300">
          <p>Still waiting for:</p>
          <ul class="mt-1 list-disc pl-5 space-y-1" data-testid="email-setup-missing-evidence">
            <li :if={not @email_setup.receiving?}>A new email received at a connected address.</li>
            <li :if={not @email_setup.sending?}>A reply sent from Custyard.</li>
            <li :if={not @email_setup.delivered?}>
              The email provider's delivery confirmation for that reply.
            </li>
            <li :if={not @email_setup.returning?}>
              A reply back from the customer's mailbox to the Custyard reply.
            </li>
          </ul>
        </div>
        <.link
          navigate={~p"/app/settings/email"}
          class="mt-2 inline-block text-sm font-medium text-indigo-600 dark:text-indigo-300"
        >{if @email_setup.configured?, do: "Continue setup", else: "Set up email"}</.link>
      </section>
      <div class="mb-3 flex items-baseline justify-between gap-3">
        <h1
          class="text-lg font-semibold text-gray-900 dark:text-zinc-100"
          data-testid="staff-queue-heading"
        >
          What needs attention
        </h1>
        <div class="flex items-baseline gap-4 text-xs text-gray-600 dark:text-zinc-400">
          <%!-- Keyboard hint: only where a keyboard is likely. --%>
          <p class="hidden lg:block" data-testid="staff-queue-keys">
            <.key>j</.key>

            <.key>k</.key>
            move
            <.key>Enter</.key>
            open
          </p>
          <span data-testid="staff-queue-count">
            {length(@threads)} {if length(@threads) == 1, do: "conversation", else: "conversations"}
          </span>
        </div>
      </div>

      <div class="mb-3 flex flex-wrap items-center gap-2">
        <div
          class="flex flex-wrap gap-1.5"
          role="group"
          aria-label="Filter by status"
          data-testid="staff-queue-filters"
        >
          <.filter_button
            :for={{value, label} <- @filters}
            filter={@filter}
            value={value}
            label={label}
            count={Map.get(@filter_counts, value, 0)}
          />
        </div>

        <form
          :if={@labels != []}
          id="queue-label-filter"
          phx-change="filter_label"
          class="ml-auto flex items-center gap-2 text-xs"
        >
          <label for="queue-label" class="text-gray-600 dark:text-zinc-300">Label</label>
          <select
            id="queue-label"
            name="label"
            class="rounded border-gray-300 py-1 pl-2 pr-8 text-xs dark:bg-zinc-800"
          >
            <option value="">All labels</option>
            <option :for={label <- @labels} value={label.id} selected={@label_id == label.id}>
              {label.name}
            </option>
          </select>
        </form>
      </div>

      <div
        :if={Enum.empty?(@threads)}
        class="rounded-lg border border-gray-200 bg-white py-12 text-center text-gray-500 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-400"
        data-testid="staff-queue-empty"
      >
        Nothing needs attention right now.
      </div>
      <%!-- j/k and the arrow keys move the selection (the focused row link),
      o or Enter opens it; data-select resumes at the conversation just left. --%>
      <ul
        :if={not Enum.empty?(@threads)}
        id="staff-queue-list"
        phx-hook="QueueKeys"
        data-select={@selected_id}
        role="list"
        class="divide-y divide-gray-200 rounded-lg border border-gray-200 bg-white dark:divide-zinc-700 dark:border-zinc-700 dark:bg-zinc-800"
        data-testid="staff-queue-list"
      >
        <.queue_row
          :for={{item, pos} <- Enum.with_index(@threads)}
          item={item}
          thread_path={thread_path(item.thread.id, @filter, @label_id, pos)}
          staff_id={@current_staff.id}
          show_score={@show_score_breakdown == item.thread.id}
          show_snooze={@show_snooze_menu == item.thread.id}
        />
      </ul>
    </div>
    """
  end

  slot :inner_block, required: true

  defp key(assigns) do
    ~H"""
    <kbd class="rounded border border-gray-300 px-1 font-sans text-[11px] text-gray-700 dark:border-zinc-600 dark:text-zinc-300">{render_slot(
      @inner_block
    )}</kbd>
    """
  end

  attr :filter, :string, required: true
  attr :value, :string, required: true
  attr :label, :string, required: true
  attr :count, :integer, required: true

  defp filter_button(assigns) do
    ~H"""
    <button
      phx-click="filter"
      phx-value-filter={@value}
      aria-pressed={to_string(@filter == @value)}
      data-testid={"staff-queue-filter-#{@value}"}
      class={[
        "inline-flex items-center gap-1.5 rounded px-2.5 py-1 text-xs focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-500",
        @filter == @value && "bg-indigo-100 font-medium text-indigo-800",
        @filter != @value &&
          "bg-gray-200 text-gray-700 hover:bg-gray-300 dark:bg-zinc-800 dark:text-zinc-300 dark:hover:bg-zinc-700"
      ]}
    >
      {@label}
      <span
        class={[
          "tabular-nums",
          if(@filter == @value, do: "text-indigo-700", else: "text-gray-600 dark:text-zinc-400")
        ]}
        data-testid={"staff-queue-filter-count-#{@value}"}
      >
        {@count}
      </span>
    </button>
    """
  end

  attr :item, :map, required: true
  attr :thread_path, :string, required: true
  attr :staff_id, :integer, required: true
  attr :show_score, :boolean, required: true
  attr :show_snooze, :boolean, required: true

  # One conversation, two lines: who and subject above, customer and the
  # latest message below. The link is the whole row; the two row actions sit
  # beside it (never inside it) in the space reserved under the age.
  defp queue_row(assigns) do
    item = assigns.item
    ours? = item.turn == :ours

    assigns =
      assigns
      |> assign(:ours?, ours?)
      |> assign(:who, who(item.thread))
      |> assign(:customer, customer_line(item.thread))
      |> assign(:age, short_age(item.last_exchange_at))
      |> assign(:age_title, age_title(item))
      |> assign(:turn_label, turn_label(item.turn))
      |> assign(:snippet_prefix, item.preview && snippet_prefix(item.preview, assigns.staff_id))
      |> assign(
        :accent,
        case item.neglect_status do
          :critical -> "border-l-red-500"
          :warning -> "border-l-amber-400"
          _ -> "border-l-transparent"
        end
      )

    ~H"""
    <li
      id={"queue-row-#{@item.thread.id}"}
      class={["group border-l-4 first:rounded-t-lg last:rounded-b-lg", @accent]}
      data-testid={"staff-queue-card-#{@item.thread.id}"}
      data-turn={@item.turn}
      data-neglect={@item.neglect_status}
    >
      <div class="relative">
        <.link
          navigate={@thread_path}
          class="grid grid-cols-[0.5rem_minmax(0,1fr)_auto_auto] gap-x-2.5 px-3 py-3 hover:bg-gray-50 focus:bg-indigo-50 focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-indigo-500 dark:hover:bg-zinc-700/40 dark:focus:bg-indigo-950/40 md:grid-cols-[0.5rem_13rem_minmax(0,1fr)_auto_4rem] md:gap-x-3"
          data-row-link
          data-testid="staff-queue-row-link"
        >
          <span class="col-start-1 row-start-1 flex h-5 items-center" aria-hidden="true">
            <span :if={@ours?} class="h-2 w-2 rounded-full bg-indigo-600 dark:bg-indigo-400" />
          </span>

          <span class="col-start-2 row-start-1 flex min-w-0 items-baseline gap-1.5 md:row-span-2 md:flex-col md:items-stretch md:gap-0">
            <span class="flex min-w-0 items-baseline gap-1.5">
              <span
                class={[
                  "truncate text-[13px] leading-5",
                  if(@ours?,
                    do: "font-semibold text-gray-900 dark:text-zinc-100",
                    else: "font-medium text-gray-600 dark:text-zinc-300"
                  )
                ]}
                data-testid="staff-queue-who"
              >
                {@who}
              </span>
              <span
                :if={@item.exchange_count > 1}
                class="shrink-0 text-xs tabular-nums text-gray-500 dark:text-zinc-400"
                title={"#{@item.exchange_count} messages exchanged with the customer"}
                data-testid="staff-queue-msg-count"
              >
                {@item.exchange_count}<span class="sr-only"> messages</span>
              </span>
            </span>
            <span
              :if={@customer}
              class="min-w-0 shrink-[3] truncate text-xs leading-5 text-gray-500 dark:text-zinc-400"
              data-testid="staff-queue-org-name"
            >
              {@customer}
            </span>
          </span>

          <span
            class={[
              "col-span-3 col-start-2 row-start-2 min-w-0 truncate text-sm leading-5 md:col-span-1 md:col-start-3 md:row-start-1",
              if(@ours?,
                do: "font-medium text-gray-950 dark:text-white",
                else: "text-gray-700 dark:text-zinc-300"
              )
            ]}
            data-testid="staff-queue-subject"
          >
            {@item.thread.subject}
          </span>
          <span
            :if={@turn_label}
            class={[
              "col-start-3 row-start-1 whitespace-nowrap text-xs leading-5 md:col-start-4",
              if(@ours?,
                do: "font-medium text-indigo-700 dark:text-indigo-300",
                else: "text-gray-500 dark:text-zinc-400"
              )
            ]}
            title={turn_title(@item)}
            data-testid="staff-queue-turn"
          >
            {@turn_label}
          </span>
          <span
            class={[
              "col-start-4 row-start-1 flex h-5 items-center justify-end gap-1 whitespace-nowrap text-xs tabular-nums md:col-start-5",
              case @item.neglect_status do
                :critical -> "font-medium text-red-600 dark:text-red-400"
                :warning -> "font-medium text-amber-700 dark:text-amber-400"
                _ -> "text-gray-500 dark:text-zinc-400"
              end
            ]}
            title={@age_title}
            data-testid="staff-queue-age"
          >
            <.icon
              :if={@item.neglect_status == :critical}
              name="hero-exclamation-triangle-mini"
              class="h-3.5 w-3.5"
            />
            <.icon :if={@item.neglect_status == :warning} name="hero-clock-mini" class="h-3.5 w-3.5" />
            <time datetime={DateTime.to_iso8601(@item.last_exchange_at)} aria-hidden="true">
              {@age}
            </time>
            <span class="sr-only">{@age_title}</span>
          </span>

          <span class="col-span-3 col-start-2 row-start-3 flex min-w-0 flex-col md:col-span-2 md:col-start-3 md:row-start-2 md:flex-row md:items-center md:gap-3">
            <span
              class="min-w-0 truncate text-[13px] leading-5 text-gray-500 dark:text-zinc-400 md:flex-1"
              data-testid="staff-queue-snippet"
            >
              <%= cond do %>
                <% is_nil(@item.preview) -> %>
                  <span class="italic">No messages yet</span>
                <% @item.preview.snippet_from == :deleted -> %>
                  <span class="italic">Message deleted</span>
                <% true -> %>
                  <span :if={@snippet_prefix} class="text-gray-700 dark:text-zinc-300">
                    {@snippet_prefix}
                  </span>
                  {@item.preview.snippet || "(no text)"}
              <% end %>
            </span>
            <span
              class="mt-1 flex max-h-5 flex-wrap items-center gap-1.5 overflow-hidden pr-16 md:mt-0 md:max-w-[24rem] md:shrink-0 md:justify-end md:pr-0"
              data-testid="staff-queue-chips"
            >
              <span
                :if={@item.due_task_count > 0}
                class="text-xs rounded px-1.5 py-0.5 bg-amber-100 dark:bg-amber-950 text-amber-800 dark:text-amber-300"
                data-testid="queue-tasks-due"
                title="Complete or reschedule the task to clear this reminder. Thread snoozing does not change its deadline."
              >
                {@item.due_task_count} {if @item.due_task_count == 1,
                  do: "task due",
                  else: "tasks due"}
              </span>
              <.urgency_badge urgency={@item.thread.urgency} />
              <span
                :if={@item.thread.suspect}
                class="text-xs px-1.5 py-0.5 rounded bg-amber-100 dark:bg-amber-950 text-amber-800 dark:text-amber-300"
                title="Triage flagged this thread as suspect"
                data-testid="staff-queue-suspect"
              >
                suspect
              </span>
              <%!-- Flag only public-intake threads: email/portal threads
                   derive their reply channel elsewhere. A badge, never a filter. --%>
              <.no_reply_channel_badge :if={
                @item.thread.source == :public_intake and @item.reply_channel == :none
              } />
              <%!-- The mail provider says nothing on a row; a source that
                   changes how the thread is handled does. --%>
              <.source_badge :if={routing_source?(@item.thread.source)} source={@item.thread.source} />
              <.state_badge state={@item.thread.state} />
              <span
                :if={@item.is_snoozed}
                class="text-xs px-1.5 py-0.5 rounded bg-gray-100 dark:bg-zinc-700 text-gray-700 dark:text-zinc-300"
                data-testid="staff-queue-snoozed"
              >
                snoozed until {format_snooze_time(@item.thread.snoozed_until)}
              </span>
              <.tier_badge
                :if={@item.thread.organization && @item.thread.organization.tier != :standard}
                tier={@item.thread.organization.tier}
              />
              <%!-- Channel the mail arrived on (spec-inbound-channels, "Attention
                   queue"): the public address, never the ingress address. --%>
              <span
                :if={@item.thread.inbound_channel}
                class="text-xs px-1.5 py-0.5 rounded bg-teal-50 dark:bg-teal-950 text-teal-700 dark:text-teal-300"
                title={"Received at #{@item.thread.inbound_channel.public_address}"}
                data-testid="staff-queue-channel"
              >
                {mailbox_local(@item.thread.inbound_channel.public_address)}
              </span>
              <span
                :for={label <- @item.labels}
                class="text-xs rounded px-1.5 py-0.5 bg-indigo-50 dark:bg-indigo-950 text-indigo-700 dark:text-indigo-300"
                data-testid={"queue-label-#{label.id}"}
              >{label.name}</span>
              <.intake_source_tag
                :if={@item.thread.intake_source_key}
                source_key={@item.thread.intake_source_key}
              />
              <span
                :if={@item.thread.language}
                class="text-xs px-1.5 py-0.5 rounded bg-gray-100 dark:bg-zinc-700 text-gray-600 dark:text-zinc-300 uppercase"
                title={"Detected language: #{Custyard.Email.LanguageDetector.name(@item.thread.language)}"}
                data-testid="staff-queue-language"
              >
                {@item.thread.language}
              </span>
            </span>
          </span>
        </.link>

        <div
          class="hover-reveal absolute bottom-1 right-2 flex items-center gap-0.5 md:bottom-1.5"
          data-open={to_string(@show_score or @show_snooze)}
        >
          <button
            type="button"
            phx-click="toggle_score"
            phx-value-id={@item.thread.id}
            aria-expanded={to_string(@show_score)}
            aria-controls={"queue-rank-#{@item.thread.id}"}
            aria-label={if @show_score, do: "Hide score", else: "Why this rank?"}
            title={if @show_score, do: "Hide score", else: "Why this rank?"}
            class={[
              "flex h-8 w-8 items-center justify-center rounded md:h-7 md:w-7 hover:bg-gray-200 hover:text-gray-900 focus-visible:outline-2 focus-visible:outline-indigo-500 dark:hover:bg-zinc-600 dark:hover:text-zinc-100",
              if(@show_score,
                do: "bg-gray-200 text-gray-900 dark:bg-zinc-600 dark:text-zinc-100",
                else: "text-gray-500 dark:text-zinc-400"
              )
            ]}
            data-testid="staff-queue-score-toggle"
          >
            <.icon name="hero-chart-bar-mini" class="h-4 w-4" />
          </button>

          <button
            :if={@item.is_snoozed}
            type="button"
            phx-click="unsnooze"
            phx-value-id={@item.thread.id}
            aria-label="Un-snooze"
            title={"Un-snooze (snoozed until #{format_snooze_time(@item.thread.snoozed_until)})"}
            class="flex h-8 w-8 items-center justify-center rounded md:h-7 md:w-7 text-indigo-600 hover:bg-indigo-50 focus-visible:outline-2 focus-visible:outline-indigo-500 dark:text-indigo-300 dark:hover:bg-indigo-900/40"
            data-testid="staff-queue-unsnooze-btn"
          >
            <.icon name="hero-bell-alert-mini" class="h-4 w-4" />
          </button>
          <%!-- The button is inside the click-away area, so clicking it while
          the menu is open closes the menu instead of closing and reopening. --%>
          <div
            :if={not @item.is_snoozed}
            class="relative"
            phx-click-away={@show_snooze && "close_snooze"}
            phx-window-keydown={@show_snooze && "close_snooze"}
            phx-key="escape"
            data-testid="staff-queue-snooze"
          >
            <button
              type="button"
              phx-click="toggle_snooze"
              phx-value-id={@item.thread.id}
              aria-haspopup="menu"
              aria-expanded={to_string(@show_snooze)}
              aria-label="Snooze"
              title="Snooze"
              class={[
                "flex h-8 w-8 items-center justify-center rounded md:h-7 md:w-7 hover:bg-gray-200 hover:text-gray-900 focus-visible:outline-2 focus-visible:outline-indigo-500 dark:hover:bg-zinc-600 dark:hover:text-zinc-100",
                if(@show_snooze,
                  do: "bg-gray-200 text-gray-900 dark:bg-zinc-600 dark:text-zinc-100",
                  else: "text-gray-500 dark:text-zinc-400"
                )
              ]}
              data-testid="staff-queue-snooze-btn"
            >
              <.icon name="hero-bell-snooze-mini" class="h-4 w-4" />
            </button>
            <div
              :if={@show_snooze}
              role="menu"
              aria-label="Snooze duration options"
              class="absolute right-0 top-full z-20 mt-1 w-28 rounded border border-gray-200 bg-white p-1 shadow-lg dark:border-zinc-600 dark:bg-zinc-800"
              data-testid="staff-queue-snooze-menu"
            >
              <p class="px-2 py-1 text-xs text-gray-500 dark:text-zinc-400">Snooze for</p>
              <button
                :for={opt <- ["1h", "4h", "1d", "3d"]}
                type="button"
                phx-click="snooze"
                phx-value-id={@item.thread.id}
                phx-value-duration={opt}
                role="menuitem"
                class="block w-full rounded px-2 py-1.5 text-left text-xs text-gray-800 hover:bg-gray-100 focus:bg-gray-100 focus:outline-none dark:text-zinc-200 dark:hover:bg-zinc-700 dark:focus:bg-zinc-700"
                data-testid={"staff-queue-snooze-opt-#{opt}"}
              >
                {opt}
              </button>
            </div>
          </div>
        </div>
      </div>

      <.rank_details :if={@show_score} item={@item} />
    </li>
    """
  end

  attr :item, :map, required: true

  # "Why this rank?": the score and the facts that no longer sit on the row.
  defp rank_details(assigns) do
    ~H"""
    <div
      id={"queue-rank-#{@item.thread.id}"}
      class="grid gap-x-8 gap-y-3 border-t border-dashed border-gray-200 px-3 py-3 text-xs dark:border-zinc-700 sm:grid-cols-[minmax(0,20rem)_minmax(0,1fr)] md:pl-8"
      data-testid="staff-queue-rank"
    >
      <div>
        <p class="mb-1.5 text-gray-600 dark:text-zinc-300">
          <span class="font-medium text-gray-900 dark:text-zinc-100" data-testid="staff-queue-score">
            Score {@item.thread.cached_score}.
          </span>
          Higher scores are listed first.
        </p>
        <.score_breakdown breakdown={@item.breakdown} show_total={false} />
      </div>
      <dl class="grid grid-cols-[auto_minmax(0,1fr)] content-start gap-x-4 gap-y-1 text-gray-700 dark:text-zinc-300">
        <dt class="text-gray-500 dark:text-zinc-400">Last staff action</dt>
        <dd data-testid="staff-queue-idle-time">
          {if @item.thread.last_staff_action_at,
            do: "#{format_idle_time(@item.hours_idle)} ago",
            else: "none since it arrived #{format_idle_time(@item.hours_idle)} ago"}
          <.neglect_badge level={@item.neglect_status} />
        </dd>
        <dt class="text-gray-500 dark:text-zinc-400">Messages</dt>
        <dd data-testid="staff-queue-rank-messages">{messages_summary(@item)}</dd>
        <%= if @item.thread.organization do %>
          <dt class="text-gray-500 dark:text-zinc-400">Customer</dt>
          <dd class="break-words">
            {@item.thread.organization.name}
            <.tier_badge
              :if={@item.thread.organization.tier == :standard}
              tier={@item.thread.organization.tier}
            />
          </dd>
        <% end %>
        <%= if @item.thread.inbound_channel do %>
          <dt class="text-gray-500 dark:text-zinc-400">Mailbox</dt>
          <dd class="break-all">{@item.thread.inbound_channel.public_address}</dd>
        <% end %>
        <%= if @item.labels != [] do %>
          <dt class="text-gray-500 dark:text-zinc-400">Labels</dt>
          <dd>{Enum.map_join(@item.labels, ", ", & &1.name)}</dd>
        <% end %>
        <%= if not routing_source?(@item.thread.source) do %>
          <dt class="text-gray-500 dark:text-zinc-400">Received via</dt>
          <dd><.source_badge source={@item.thread.source} /></dd>
        <% end %>
      </dl>
    </div>
    """
  end

  # Email providers are plumbing; every other source changes how the thread
  # is handled (needs routing, public intake, portal, chat tools).
  defp routing_source?(source), do: source not in [:email, :lettermint]
end
