defmodule CustyardWeb.OperatorComponents do
  @moduledoc """
  Shared UI components for the operator interface.

  These components are used across multiple operator LiveViews and provide
  consistent styling for badges, breakdowns, and other UI elements.
  """
  use Phoenix.Component

  @doc """
  Renders a tier badge (enterprise/standard/basic).

  ## Examples

      <.tier_badge tier={:enterprise} />
  """
  attr :tier, :atom, required: true

  def tier_badge(assigns) do
    colors =
      case assigns.tier do
        :enterprise -> "text-purple-700 dark:text-purple-300 bg-purple-50 dark:bg-purple-950"
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

  @doc """
  Renders a conversation state badge (new/active/waiting/dormant/resolved).

  ## Examples

      <.state_badge state={:active} />
  """
  attr :state, :atom, required: true

  def state_badge(assigns) do
    colors =
      case assigns.state do
        :new -> "bg-blue-100 dark:bg-blue-950 text-blue-800 dark:text-blue-300"
        :active -> "bg-green-100 dark:bg-green-950 text-green-800 dark:text-green-300"
        :waiting -> "bg-yellow-100 dark:bg-yellow-950 text-yellow-800 dark:text-yellow-300"
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

  @doc """
  Renders a neglect level badge (critical/warning).

  Only renders for :critical and :warning levels. Renders nothing for :ok.

  ## Examples

      <.neglect_badge level={:critical} />
  """
  attr :level, :atom, required: true

  def neglect_badge(assigns) do
    ~H"""
    <%= case @level do %>
      <% :critical -> %>
        <span
          class="text-xs px-1.5 py-0.5 rounded border bg-red-100 dark:bg-red-950 text-red-800 dark:text-red-300 border-red-300 dark:border-red-700"
          data-testid="operator-neglect-badge-critical"
        >
          NEGLECTED
        </span>
      <% :warning -> %>
        <span
          class="text-xs px-1.5 py-0.5 rounded border bg-amber-100 dark:bg-amber-950 text-amber-800 dark:text-amber-300 border-amber-300 dark:border-amber-700"
          data-testid="operator-neglect-badge-warning"
        >
          aging
        </span>
      <% _ -> %>
    <% end %>
    """
  end

  @doc """
  Renders an urgency badge (urgent/elevated).

  Only renders for :urgent and :elevated. Renders nothing for :normal.

  ## Examples

      <.urgency_badge urgency={:urgent} />
  """
  attr :urgency, :atom, required: true

  def urgency_badge(assigns) do
    ~H"""
    <%= case @urgency do %>
      <% :urgent -> %>
        <span
          class="text-xs px-1.5 py-0.5 rounded font-medium bg-red-100 dark:bg-red-950 text-red-800 dark:text-red-300"
          data-testid="operator-urgency-badge-urgent"
        >
          urgent
        </span>
      <% :elevated -> %>
        <span
          class="text-xs px-1.5 py-0.5 rounded font-medium bg-orange-100 dark:bg-orange-950 text-orange-800 dark:text-orange-300"
          data-testid="operator-urgency-badge-elevated"
        >
          elevated
        </span>
      <% _ -> %>
    <% end %>
    """
  end

  @doc """
  Renders a score breakdown visualization.

  Shows a bar chart of scoring factors with their relative contributions.

  ## Examples

      <.score_breakdown breakdown={%{idle: 10, state: 15, tier: 20, urgency: 0, velocity: 5, neglect_bonus: 0, total: 50}} />
  """
  attr :breakdown, :map, required: true
  attr :show_total, :boolean, default: true

  def score_breakdown(assigns) do
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
      class="p-2 bg-gray-50 dark:bg-zinc-800 rounded text-xs space-y-1"
      data-testid="operator-score-breakdown"
    >
      <div class="font-medium text-gray-700 dark:text-zinc-300 mb-1">
        Score breakdown{if @show_total, do: " (total: #{@breakdown.total})", else: ""}
      </div>
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
