defmodule CustyardWeb.Staff.TasksLive do
  @moduledoc """
  Every task of the tenant in one list, whatever it is attached to.

  The page works like the attention queue: filter chips with counts, one
  two-line row per task that links to where the task lives, and the same
  keys. The filter, the order and the customer are kept in the URL.
  """

  use CustyardWeb, :live_view

  import CustyardWeb.StaffComponents

  alias Custyard.{Organizations, Tasks, Threads, WorkItem}

  # Debounce delay for PubSub-triggered reloads (milliseconds), as in the
  # attention queue: many updates in a row cost one reload.
  @reload_debounce_ms 500

  # How often the due words are brought up to date (milliseconds).
  @tick_ms 60_000

  @filters [
    {"open", "open"},
    {"due", "due"},
    {"upcoming", "upcoming"},
    {"no_date", "no due date"},
    {"done", "done"},
    {"all", "all"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(
        Custyard.PubSub,
        Threads.tasks_topic(socket.assigns.current_tenant.id)
      )

      Process.send_after(self(), :tick, @tick_ms)
    end

    # The tasks are loaded by handle_params/3, which always runs after mount
    # and before the first render.
    socket =
      socket
      |> assign(:page_title, "All tasks")
      |> assign(:customers, nil)
      |> assign(:reload_timer, nil)
      |> assign(:announcement, nil)

    {:ok, socket, layout: {CustyardWeb.Layouts, :staff}}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    # The customers are read once per visit. A chip or the sort toggle only
    # patches the URL, and that should not read them again.
    customers = socket.assigns.customers || Organizations.list(socket.assigns.current_scope)
    filter = if params["filter"] in Tasks.filters(), do: params["filter"]

    socket =
      socket
      |> assign(:customers, customers)
      |> assign(:customer, Enum.find(customers, &(&1.public_id == params["customer"])))
      |> assign(:filter, filter || Tasks.default_filter())
      |> assign(:reverse, params["reverse"] == "1")
      |> load_tasks()

    {:noreply, socket}
  end

  @impl true
  def handle_event("filter", %{"filter" => filter}, socket) do
    {:noreply, push_patch(socket, to: tasks_path(socket, filter: filter))}
  end

  def handle_event("toggle_reverse", _params, socket) do
    {:noreply, push_patch(socket, to: tasks_path(socket, reverse: not socket.assigns.reverse))}
  end

  def handle_event("filter_customer", %{"customer" => public_id}, socket) do
    {:noreply, push_patch(socket, to: tasks_path(socket, customer: public_id))}
  end

  # The button names the state it wants, not "toggle": the row may be out of
  # date, and marking a task done twice must leave it done.
  def handle_event("set_task_state", %{"id" => id, "state" => state}, socket)
      when state in ["done", "open"] do
    case Enum.find(socket.assigns.tasks, &(to_string(&1.id) == id)) do
      nil ->
        # Not a task on this page.
        {:noreply, socket}

      task ->
        new_state = if state == "done", do: :done, else: :open

        case Tasks.set_state(socket.assigns.current_scope, task, new_state) do
          {:ok, _task} ->
            # The row may leave the list, so say what happened where a screen
            # reader hears it (the QueueKeys hook moves focus to the next row).
            said = if new_state == :done, do: "Marked done", else: "Reopened"

            {:noreply, socket |> assign(:announcement, "#{said}: #{task.title}") |> load_tasks()}

          {:error, :not_found} ->
            {:noreply, socket |> put_flash(:error, "That task no longer exists") |> load_tasks()}

          {:error, :unauthorized} ->
            {:noreply,
             socket
             |> put_flash(:error, "You no longer have access to this task")
             |> load_tasks()}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to update task")}
        end
    end
  end

  def handle_event("set_task_state", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info({:task_changed, _id}, socket) do
    {:noreply, schedule_reload(socket)}
  end

  # Debounced reload timer fired - perform the actual reload
  def handle_info(:debounced_reload, socket) do
    {:noreply, socket |> assign(:reload_timer, nil) |> load_tasks()}
  end

  # The due words count from now, so they are refreshed every minute. The
  # tasks are read again only when one has become due since the last load:
  # that changes the counts and may change the list.
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @tick_ms)
    now = now()
    next_due_at = socket.assigns.next_due_at

    if next_due_at && DateTime.compare(next_due_at, now) != :gt,
      do: {:noreply, load_tasks(socket)},
      else: {:noreply, assign(socket, :now, now)}
  end

  # Catch-all for unexpected PubSub messages to prevent LiveView crashes
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  # Schedule a debounced reload - cancel any pending timer first
  defp schedule_reload(socket) do
    if timer = socket.assigns.reload_timer do
      Process.cancel_timer(timer)
    end

    timer = Process.send_after(self(), :debounced_reload, @reload_debounce_ms)
    assign(socket, :reload_timer, timer)
  end

  defp load_tasks(socket) do
    now = now()
    customer = socket.assigns.customer

    # One call: the staff member is checked once, and the list and the counts
    # are taken at the same moment.
    page =
      Tasks.page(socket.assigns.current_scope,
        filter: socket.assigns.filter,
        reverse: socket.assigns.reverse,
        organization_id: customer && customer.id,
        now: now
      )

    socket
    |> assign(:tasks, page.tasks)
    |> assign(:counts, page.counts)
    |> assign(:next_due_at, page.next_due_at)
    |> assign(:now, now)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  # The page's URL with some of its state changed. What is at its default is
  # left out, so the plain page keeps the plain address.
  defp tasks_path(socket, changes) do
    %{filter: filter, reverse: reverse, customer: customer} = socket.assigns

    state =
      Keyword.merge(
        [filter: filter, reverse: reverse, customer: customer && customer.public_id],
        changes
      )

    params =
      Enum.reject(
        [
          filter: if(state[:filter] != Tasks.default_filter(), do: state[:filter]),
          reverse: if(state[:reverse], do: 1),
          customer: if(state[:customer] != "", do: state[:customer])
        ],
        fn {_key, value} -> is_nil(value) end
      )

    ~p"/app/tasks?#{params}"
  end

  # A row opens where the task lives: its conversation if it has one,
  # otherwise its project, otherwise its customer.
  defp task_path(%WorkItem{thread_id: id}) when is_integer(id), do: ~p"/app/threads/#{id}"
  defp task_path(%WorkItem{project_id: id}) when is_integer(id), do: ~p"/app/projects/#{id}"

  defp task_path(%WorkItem{organization: %{public_id: public_id}}),
    do: ~p"/app/customers/#{public_id}"

  defp task_path(_task), do: ~p"/app/tasks"

  defp place(%WorkItem{thread: %{subject: subject}}),
    do: {"Conversation", subject || "(no subject)"}

  defp place(%WorkItem{project: %{title: title}}), do: {"Project", title}
  defp place(_task), do: nil

  # The due date in a few words, and how much it should stand out. Finished
  # tasks keep their date but are never overdue.
  defp due(%WorkItem{due_at: nil}, _now), do: %{status: :none, words: "no due date", title: nil}

  defp due(%WorkItem{state: :done, due_at: due_at}, now) do
    %{status: :closed, words: "due #{short_date(due_at, now)}", title: due_title(due_at)}
  end

  defp due(%WorkItem{due_at: due_at}, now) do
    {status, words} =
      case DateTime.compare(due_at, now) do
        :gt -> {:upcoming, in_words("due in", short_age(now, due_at))}
        _ -> {:overdue, in_words("overdue", short_age(due_at, now))}
      end

    %{status: status, words: words, title: due_title(due_at)}
  end

  # short_age/2 says "now" for anything under a minute.
  defp in_words(_prefix, "now"), do: "due now"
  defp in_words(prefix, span), do: "#{prefix} #{span}"

  defp due_title(due_at), do: "Due #{format_timestamp(due_at)}"

  defp short_date(%DateTime{year: year} = at, %DateTime{year: year}),
    do: Calendar.strftime(at, "%b %-d")

  defp short_date(at, _now), do: Calendar.strftime(at, "%b %-d, %Y")

  defp status_label(:in_progress), do: "In progress"
  defp status_label(:done), do: "Done"
  defp status_label(_open), do: "Open"

  @nothing %{
    "open" => "No open tasks",
    "due" => "No tasks are due",
    "upcoming" => "No upcoming tasks",
    "no_date" => "No open tasks without a due date",
    "done" => "No finished tasks",
    "all" => "No tasks yet"
  }

  defp empty_message(filter, %{name: name}), do: "#{@nothing[filter]} for #{name}."

  defp empty_message("all", nil),
    do: "#{@nothing["all"]}. Add a task from a conversation or a project."

  defp empty_message(filter, nil), do: "#{@nothing[filter]}."

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :filters, @filters)

    ~H"""
    <div class="mx-auto w-full max-w-6xl px-3 py-4 sm:px-4" data-testid="staff-tasks-page">
      <p class="sr-only" role="status" aria-live="polite" data-testid="staff-tasks-announcement">
        {@announcement}
      </p>
      <div class="mb-3 flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
        <h1
          class="text-lg font-semibold text-gray-900 dark:text-zinc-100"
          data-testid="staff-tasks-heading"
        >
          All tasks
        </h1>
        <%!-- Key hint, count, order: the same sequence as the attention queue. --%>
        <div class="flex flex-wrap items-baseline gap-x-4 gap-y-1 text-xs text-gray-600 dark:text-zinc-400">
          <%!-- Keyboard hint: only where a keyboard is likely. --%>
          <p class="hidden lg:block" data-testid="staff-tasks-keys">
            <.kbd>j</.kbd>

            <.kbd>k</.kbd>
            move
            <.kbd>Enter</.kbd>
            open
          </p>
          <span class="whitespace-nowrap" data-testid="staff-tasks-count">
            {length(@tasks)} {if length(@tasks) == 1, do: "task", else: "tasks"}
          </span>
          <%!-- Finished tasks are listed by when they were last changed. --%>
          <.sort_toggle
            reversed={@reverse}
            label={if @filter == "done", do: "Latest change first", else: "Due soonest first"}
            reversed_label={
              if @filter == "done", do: "Earliest change first", else: "Due latest first"
            }
            testid="staff-tasks-sort"
          />
        </div>
      </div>

      <div class="mb-3 flex flex-wrap items-center gap-2">
        <div
          class="flex flex-wrap gap-1.5"
          role="group"
          aria-label="Filter by status"
          data-testid="staff-tasks-filters"
        >
          <.filter_chip
            :for={{value, label} <- @filters}
            current={@filter}
            value={value}
            label={label}
            count={Map.get(@counts, value, 0)}
            testid="staff-tasks-filter"
          />
        </div>

        <form
          :if={@customers != []}
          id="tasks-customer-filter"
          phx-change="filter_customer"
          class="ml-auto flex items-center gap-2 text-xs"
        >
          <label for="tasks-customer" class="text-gray-600 dark:text-zinc-300">Customer</label>
          <select
            id="tasks-customer"
            name="customer"
            class="rounded border-gray-300 py-1 pl-2 pr-8 text-xs dark:bg-zinc-800"
          >
            <option value="">All customers</option>
            <option
              :for={customer <- @customers}
              value={customer.public_id}
              selected={@customer && @customer.id == customer.id}
            >
              {customer.name}
            </option>
          </select>
        </form>
      </div>

      <%!-- j/k and the arrow keys move the selection (the focused row link),
      o or Enter opens it. The hook is on the element around the list: when
      the last row leaves, it moves the focus to the note that the list is
      empty. --%>
      <div id="staff-tasks-rows" phx-hook="QueueKeys">
        <div
          :if={Enum.empty?(@tasks)}
          tabindex="-1"
          data-list-empty
          class="rounded-lg border border-gray-200 bg-white py-12 text-center text-gray-500 focus-visible:outline-2 focus-visible:outline-indigo-500 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-400"
          data-testid="staff-tasks-empty"
        >
          {empty_message(@filter, @customer)}
        </div>
        <ul
          :if={not Enum.empty?(@tasks)}
          id="staff-tasks-list"
          role="list"
          class="divide-y divide-gray-200 rounded-lg border border-gray-200 bg-white dark:divide-zinc-700 dark:border-zinc-700 dark:bg-zinc-800"
          data-testid="staff-tasks-list"
        >
          <.task_row :for={task <- @tasks} task={task} now={@now} />
        </ul>
      </div>
    </div>
    """
  end

  attr :task, WorkItem, required: true
  attr :now, DateTime, required: true

  # One task, two lines: the title and the due date above, where the task
  # lives below. The link is the whole row; the row action sits beside it
  # (never inside it) in the space reserved under the due date.
  defp task_row(assigns) do
    task = assigns.task

    assigns =
      assigns
      |> assign(:done?, task.state == :done)
      |> assign(:status_label, status_label(task.state))
      |> assign(:due, due(task, assigns.now))
      |> assign(:place, place(task))
      |> assign(:customer, task.organization && task.organization.name)
      |> assign(:path, task_path(task))

    ~H"""
    <li
      id={"task-row-#{@task.id}"}
      class={[
        "group border-l-4 first:rounded-t-lg last:rounded-b-lg",
        if(@due.status == :overdue, do: "border-l-red-500", else: "border-l-transparent")
      ]}
      data-testid={"staff-task-row-#{@task.id}"}
      data-state={@task.state}
      data-due={@due.status}
    >
      <div class="relative">
        <.link
          navigate={@path}
          class="grid grid-cols-[1rem_minmax(0,1fr)_auto] gap-x-2.5 px-3 py-3 hover:bg-gray-50 focus:bg-indigo-50 focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-indigo-500 dark:hover:bg-zinc-700/40 dark:focus:bg-indigo-950/40 md:gap-x-3"
          data-row-link
          data-testid="staff-task-row-link"
        >
          <span
            class="col-start-1 row-start-1 flex h-5 items-center justify-center"
            title={@status_label}
            data-testid="staff-task-status"
          >
            <%!-- A shape for each state, so the state does not rest on colour. --%>
            <.icon
              :if={@task.state == :done}
              name="hero-check-circle-mini"
              class="h-4 w-4 text-green-600 dark:text-green-400"
            />
            <span
              :if={@task.state == :in_progress}
              class="flex h-3 w-3 items-center justify-center rounded-full border-2 border-blue-500 dark:border-blue-400"
              aria-hidden="true"
            >
              <span class="h-1 w-1 rounded-full bg-blue-500 dark:bg-blue-400" />
            </span>
            <span
              :if={@task.state not in [:done, :in_progress]}
              class="h-3 w-3 rounded-full border-2 border-gray-400 dark:border-zinc-500"
              aria-hidden="true"
            />
            <span class="sr-only">{@status_label}:</span>
          </span>

          <span
            class={[
              "col-start-2 row-start-1 min-w-0 truncate text-sm leading-5",
              if(@done?,
                do: "text-gray-500 line-through dark:text-zinc-400",
                else: "font-medium text-gray-950 dark:text-white"
              )
            ]}
            data-testid="staff-task-title"
          >
            {@task.title}
          </span>
          <span
            class={[
              "col-start-3 row-start-1 flex h-5 items-center justify-end gap-1 whitespace-nowrap text-xs tabular-nums",
              case @due.status do
                :overdue -> "font-medium text-red-600 dark:text-red-400"
                :upcoming -> "text-gray-700 dark:text-zinc-300"
                _ -> "text-gray-500 dark:text-zinc-400"
              end
            ]}
            title={@due.title}
            data-testid="staff-task-due"
          >
            <.icon
              :if={@due.status == :overdue}
              name="hero-exclamation-triangle-mini"
              class="h-3.5 w-3.5"
            />
            <time :if={@task.due_at} datetime={DateTime.to_iso8601(@task.due_at)}>
              {@due.words}
            </time>
            <span :if={is_nil(@task.due_at)}>{@due.words}</span>
          </span>

          <span class="col-span-2 col-start-2 row-start-2 flex min-w-0 items-center gap-1.5 text-[13px] leading-5 text-gray-500 dark:text-zinc-400">
            <span :if={@place} class="min-w-0 truncate" data-testid="staff-task-place">
              <span class="text-gray-700 dark:text-zinc-300">{elem(@place, 0)}:</span>
              {elem(@place, 1)}
            </span>
            <span :if={@place && @customer} aria-hidden="true">·</span>
            <span
              :if={@customer}
              class={["truncate", if(@place, do: "max-w-[45%] shrink-0", else: "min-w-0")]}
              data-testid="staff-task-customer"
            >
              {@customer}
            </span>
            <%!-- The right padding keeps the chips clear of the row action. --%>
            <span
              class="ml-auto flex shrink-0 items-center gap-1.5 pl-1.5 pr-9"
              data-testid="staff-task-chips"
            >
              <span
                :if={@task.portal_visible}
                class="text-xs rounded px-1.5 py-0.5 bg-cyan-50 dark:bg-cyan-950 text-cyan-700 dark:text-cyan-300"
                title="The customer can see this task in the portal"
                data-testid="staff-task-portal"
              >
                in portal
              </span>
            </span>
          </span>
        </.link>

        <div class="hover-reveal absolute bottom-1 right-2 flex items-center gap-0.5 md:bottom-1.5">
          <button
            type="button"
            phx-click="set_task_state"
            phx-value-id={@task.id}
            phx-value-state={if @done?, do: "open", else: "done"}
            aria-label={"#{if @done?, do: "Reopen", else: "Mark done"}: #{@task.title}"}
            title={if @done?, do: "Reopen", else: "Mark done"}
            class="flex h-8 w-8 items-center justify-center rounded md:h-7 md:w-7 text-gray-500 hover:bg-gray-200 hover:text-gray-900 focus-visible:outline-2 focus-visible:outline-indigo-500 dark:text-zinc-400 dark:hover:bg-zinc-600 dark:hover:text-zinc-100"
            data-testid="staff-task-action"
            data-action={if @done?, do: "reopen", else: "done"}
          >
            <.icon
              name={if @done?, do: "hero-arrow-uturn-left-mini", else: "hero-check-mini"}
              class="h-4 w-4"
            />
          </button>
        </div>
      </div>
    </li>
    """
  end
end
