defmodule CustyardWeb.Operator.NeglectReportLive do
  @moduledoc """
  Dedicated view showing all conversations at warning or critical neglect status,
  grouped by organization. Useful for triage after being away or during volume spikes.
  """
  use CustyardWeb, :live_view

  alias Custyard.{Conversations, Scoring}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Custyard.PubSub, "conversations")
    end

    socket =
      socket
      |> assign(:page_title, "Neglect Report")
      |> load_neglected()

    {:ok, socket, layout: {CustyardWeb.Layouts, :operator}}
  end

  @impl true
  def handle_info({:conversation_updated, _id}, socket) do
    {:noreply, load_neglected(socket)}
  end

  def handle_info({:conversation_created, _id}, socket) do
    {:noreply, load_neglected(socket)}
  end

  defp load_neglected(socket) do
    conversations = Conversations.list_neglected()

    # Filter to only neglected items and enrich with status
    neglected =
      conversations
      |> Enum.map(fn conv ->
        neglect_status = Scoring.neglect_status(conv)
        hours_idle = hours_since(conv.last_operator_action_at || conv.inserted_at)
        {conv, neglect_status, hours_idle}
      end)
      |> Enum.filter(fn {_, status, _} -> status in [:warning, :critical] end)
      |> Enum.map(fn {conv, status, hours_idle} ->
        %{
          conversation: conv,
          neglect_status: status,
          hours_idle: hours_idle
        }
      end)

    # Group by organization
    grouped =
      neglected
      |> Enum.group_by(fn item -> item.conversation.organization end)
      |> Enum.sort_by(fn {org, items} ->
        # Sort orgs by most critical items first, then by name
        critical_count = Enum.count(items, &(&1.neglect_status == :critical))
        {-critical_count, org.name}
      end)

    total_count = length(neglected)
    critical_count = Enum.count(neglected, &(&1.neglect_status == :critical))
    warning_count = total_count - critical_count

    socket
    |> assign(:grouped_conversations, grouped)
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

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto p-4">
      <div class="flex items-center gap-3 mb-4">
        <.link navigate={~p"/operator"} class="text-sm text-gray-500 hover:text-gray-700">
          &larr; Queue
        </.link>
        <h1 class="text-lg font-semibold text-gray-900">Neglect Report</h1>
        <span class="text-sm text-gray-400">{@total_count} items past threshold</span>
      </div>

      <div :if={@total_count > 0} class="flex gap-4 mb-6 text-sm">
        <div :if={@critical_count > 0} class="flex items-center gap-1.5">
          <span class="w-2.5 h-2.5 rounded-full bg-red-500"></span>
          <span class="text-gray-600">{@critical_count} critical</span>
        </div>
        <div :if={@warning_count > 0} class="flex items-center gap-1.5">
          <span class="w-2.5 h-2.5 rounded-full bg-amber-400"></span>
          <span class="text-gray-600">{@warning_count} warning</span>
        </div>
      </div>

      <div :if={@total_count == 0} class="text-center text-gray-400 py-12">
        No items are currently past their neglect thresholds.
      </div>

      <div class="space-y-6">
        <div :for={{org, items} <- @grouped_conversations}>
          <div class="flex items-center gap-2 mb-2">
            <span class="text-sm font-medium text-gray-700">{org.name}</span>
            <.tier_badge tier={org.tier} />
            <span class="text-xs text-gray-400">{length(items)} items</span>
          </div>

          <div class="space-y-2">
            <.link
              :for={item <- items}
              navigate={~p"/operator/conversation/#{item.conversation.id}"}
              class="block"
            >
              <div class={[
                "bg-white border border-gray-200 rounded-lg p-3 hover:shadow-sm transition-shadow flex items-center gap-3 border-l-4",
                border_color(item.neglect_status)
              ]}>
                <.neglect_badge level={item.neglect_status} />
                <div class="flex-1 min-w-0">
                  <div class="text-sm text-gray-800 truncate">{item.conversation.subject}</div>
                  <div class="text-xs text-gray-500">
                    {if item.conversation.contact,
                      do: item.conversation.contact.name || item.conversation.contact.email,
                      else: "Unknown contact"}
                  </div>
                </div>
                <span class="text-xs text-gray-400 whitespace-nowrap">
                  {format_idle_time(item.hours_idle)}
                </span>
              </div>
            </.link>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp border_color(:critical), do: "border-l-red-500"
  defp border_color(:warning), do: "border-l-amber-400"
  defp border_color(_), do: "border-l-transparent"

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

  attr :level, :atom, required: true

  defp neglect_badge(assigns) do
    ~H"""
    <span
      :if={@level == :critical}
      class="text-xs px-1.5 py-0.5 rounded border bg-red-100 text-red-800 border-red-300"
    >
      NEGLECTED
    </span>
    <span
      :if={@level == :warning}
      class="text-xs px-1.5 py-0.5 rounded border bg-amber-100 text-amber-800 border-amber-300"
    >
      aging
    </span>
    """
  end
end
