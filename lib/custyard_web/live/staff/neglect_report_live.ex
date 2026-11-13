defmodule CustyardWeb.Staff.NeglectReportLive do
  @moduledoc """
  Dedicated view showing all threads at warning or critical neglect status,
  grouped by organization. Useful for triage after being away or during volume spikes.
  """
  use CustyardWeb, :live_view

  import CustyardWeb.StaffComponents

  alias Custyard.{Threads, Scoring}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Custyard.PubSub, "threads")
    end

    socket =
      socket
      |> assign(:page_title, "Neglect report")
      |> load_neglected()

    {:ok, socket, layout: {CustyardWeb.Layouts, :staff}}
  end

  @impl true
  def handle_info({:thread_updated, _id}, socket) do
    {:noreply, load_neglected(socket)}
  end

  @impl true
  def handle_info({:thread_created, _id}, socket) do
    {:noreply, load_neglected(socket)}
  end

  # Catch-all for unexpected PubSub messages to prevent LiveView crashes
  @impl true
  def handle_info(_msg, socket) do
    {:noreply, socket}
  end

  defp load_neglected(socket) do
    threads =
      Threads.neglected(socket.assigns.current_scope)

    # Filter to only neglected items and enrich with status
    neglected =
      threads
      |> Enum.map(fn conv ->
        neglect_status = Scoring.neglect_status(conv)
        hours_idle = hours_since(conv.last_staff_action_at || conv.inserted_at)
        {conv, neglect_status, hours_idle}
      end)
      |> Enum.filter(fn {_, status, _} -> status in [:warning, :critical] end)
      |> Enum.map(fn {conv, status, hours_idle} ->
        %{
          thread: conv,
          neglect_status: status,
          hours_idle: hours_idle
        }
      end)

    # Group by organization
    grouped =
      neglected
      |> Enum.group_by(fn item -> item.thread.organization end)
      |> Enum.sort_by(fn {org, items} ->
        # Sort orgs by most critical items first, then by name.
        # org is nil for unlinked prospect threads (e.g. disambiguation).
        critical_count = Enum.count(items, &(&1.neglect_status == :critical))
        {-critical_count, (org && org.name) || ""}
      end)

    total_count = length(neglected)
    critical_count = Enum.count(neglected, &(&1.neglect_status == :critical))
    warning_count = total_count - critical_count

    socket
    |> assign(:grouped_threads, grouped)
    |> assign(:total_count, total_count)
    |> assign(:critical_count, critical_count)
    |> assign(:warning_count, warning_count)
  end

  defp hours_since(nil), do: 0

  defp hours_since(datetime) do
    DateTime.diff(DateTime.utc_now(), datetime, :hour)
  end

  defp format_idle_time(hours) when hours < 24, do: "#{hours}h idle"
  defp format_idle_time(hours), do: "#{div(hours, 24)}d idle"

  # The page belongs to the attention queue section, so it uses the queue's
  # container, heading row and bordered list. The second row of the
  # navigation links back to the queue.
  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-full max-w-6xl px-3 py-4 sm:px-4" data-testid="staff-neglect-page">
      <div class="mb-3 flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
        <h1
          class="text-lg font-semibold text-gray-900 dark:text-zinc-100"
          data-testid="staff-neglect-heading"
        >
          Neglect report
        </h1>
        <div class="flex flex-wrap items-baseline gap-x-4 gap-y-1 text-xs text-gray-600 dark:text-zinc-400">
          <span
            :if={@critical_count > 0}
            class="inline-flex items-baseline gap-1.5"
            data-testid="staff-neglect-critical-count"
          >
            <span class="h-2 w-2 rounded-full bg-red-500" aria-hidden="true"></span>
            {@critical_count} critical
          </span>
          <span
            :if={@warning_count > 0}
            class="inline-flex items-baseline gap-1.5"
            data-testid="staff-neglect-warning-count"
          >
            <span class="h-2 w-2 rounded-full bg-amber-400" aria-hidden="true"></span>
            {@warning_count} warning
          </span>
          <span data-testid="staff-neglect-count">
            {@total_count} {if @total_count == 1, do: "item", else: "items"} past threshold
          </span>
        </div>
      </div>

      <div
        :if={@total_count == 0}
        class="rounded-lg border border-gray-200 bg-white py-12 text-center text-gray-500 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-400"
        data-testid="staff-neglect-empty"
      >
        No items are currently past their neglect thresholds.
      </div>

      <div class="space-y-5">
        <section :for={{org, items} <- @grouped_threads} data-testid="staff-neglect-org-group">
          <div class="mb-1.5 flex items-center gap-2">
            <h2
              class="text-sm font-medium text-gray-700 dark:text-zinc-300"
              data-testid="staff-neglect-org-name"
            >
              {if org, do: org.name, else: "Unlinked prospect"}
            </h2>
            <.tier_badge :if={org} tier={org.tier} />
            <span class="text-xs text-gray-600 dark:text-zinc-400">
              {length(items)} {if length(items) == 1, do: "item", else: "items"}
            </span>
          </div>

          <ul
            role="list"
            class="divide-y divide-gray-200 rounded-lg border border-gray-200 bg-white dark:divide-zinc-700 dark:border-zinc-700 dark:bg-zinc-800"
          >
            <li
              :for={item <- items}
              class={[
                "border-l-4 first:rounded-t-lg last:rounded-b-lg",
                border_color(item.neglect_status)
              ]}
            >
              <.link
                navigate={~p"/app/threads/#{item.thread.id}"}
                class="flex items-center gap-3 px-3 py-2.5 hover:bg-gray-50 focus:bg-indigo-50 focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-indigo-500 dark:hover:bg-zinc-700/40 dark:focus:bg-indigo-950/40"
                data-testid={"staff-neglect-item-#{item.thread.id}"}
              >
                <.neglect_badge level={item.neglect_status} />
                <span class="min-w-0 flex-1">
                  <span
                    class="block truncate text-sm leading-5 text-gray-900 dark:text-zinc-100"
                    data-testid="staff-neglect-subject"
                  >
                    {item.thread.subject}
                  </span>
                  <span
                    class="block truncate text-xs leading-5 text-gray-500 dark:text-zinc-400"
                    data-testid="staff-neglect-contact"
                  >
                    {if item.thread.contact,
                      do: item.thread.contact.name || item.thread.contact.email,
                      else: "Unknown contact"}
                  </span>
                </span>
                <span
                  class={[
                    "whitespace-nowrap text-xs font-medium tabular-nums",
                    idle_color(item.neglect_status)
                  ]}
                  data-testid="staff-neglect-idle-time"
                >
                  {format_idle_time(item.hours_idle)}
                </span>
              </.link>
            </li>
          </ul>
        </section>
      </div>
    </div>
    """
  end

  defp border_color(:critical), do: "border-l-red-500"
  defp border_color(:warning), do: "border-l-amber-400"
  defp border_color(_), do: "border-l-transparent"

  # The same colours the queue gives a conversation's age.
  defp idle_color(:critical), do: "text-red-600 dark:text-red-400"
  defp idle_color(:warning), do: "text-amber-700 dark:text-amber-400"
  defp idle_color(_), do: "text-gray-500 dark:text-zinc-400"
end
