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
  Renders a route type badge (general/project/disambiguation).

  ## Examples

      <.route_type_badge type={:general} />
  """
  attr :type, :atom, required: true

  def route_type_badge(assigns) do
    colors =
      case assigns.type do
        :general -> "text-blue-700 dark:text-blue-300 bg-blue-50 dark:bg-blue-950"
        :project -> "text-green-700 dark:text-green-300 bg-green-50 dark:bg-green-950"
        :disambiguation -> "text-amber-700 dark:text-amber-300 bg-amber-50 dark:bg-amber-950"
        _ -> "text-gray-600 dark:text-zinc-400 bg-gray-50 dark:bg-zinc-800"
      end

    assigns = assign(assigns, :colors, colors)

    ~H"""
    <span
      class={"text-xs px-1.5 py-0.5 rounded #{@colors}"}
      data-testid={"route-type-badge-#{@type}"}
    >
      {to_string(@type)}
    </span>
    """
  end

  @doc """
  Renders a source badge with a human label for the conversation/route source.

  Known sources get a curated label and color; any other atom falls back to a
  humanized label with neutral styling, so new source values render sensibly
  without requiring a change here.

  ## Examples

      <.source_badge source={:lettermint} />
  """
  attr :source, :atom, required: true

  def source_badge(assigns) do
    assigns =
      assigns
      |> assign(:colors, source_colors(assigns.source))
      |> assign(:label, source_label(assigns.source))

    ~H"""
    <span
      class={"text-xs px-1.5 py-0.5 rounded #{@colors}"}
      data-testid={"source-badge-#{@source}"}
    >
      {@label}
    </span>
    """
  end

  defp source_colors(:lettermint),
    do: "text-indigo-700 dark:text-indigo-300 bg-indigo-50 dark:bg-indigo-950"

  defp source_colors(:zendesk),
    do: "text-green-700 dark:text-green-300 bg-green-50 dark:bg-green-950"

  defp source_colors(:intercom),
    do: "text-blue-700 dark:text-blue-300 bg-blue-50 dark:bg-blue-950"

  defp source_colors(:slack),
    do: "text-purple-700 dark:text-purple-300 bg-purple-50 dark:bg-purple-950"

  defp source_colors(:email), do: "text-teal-700 dark:text-teal-300 bg-teal-50 dark:bg-teal-950"
  defp source_colors(:portal), do: "text-cyan-700 dark:text-cyan-300 bg-cyan-50 dark:bg-cyan-950"

  defp source_colors(:disambiguation),
    do: "text-amber-700 dark:text-amber-300 bg-amber-50 dark:bg-amber-950"

  defp source_colors(:public_intake),
    do: "text-rose-700 dark:text-rose-300 bg-rose-50 dark:bg-rose-950"

  defp source_colors(_other), do: "text-gray-600 dark:text-zinc-400 bg-gray-50 dark:bg-zinc-800"

  defp source_label(:email), do: "Email"
  defp source_label(:lettermint), do: "Lettermint"
  defp source_label(:zendesk), do: "Zendesk"
  defp source_label(:intercom), do: "Intercom"
  defp source_label(:slack), do: "Slack"
  defp source_label(:portal), do: "Portal"
  defp source_label(:disambiguation), do: "Needs routing"
  defp source_label(:public_intake), do: "Public intake"

  defp source_label(other) do
    other |> to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  @doc """
  Renders a tag-style badge for a conversation's intake source key (CTA
  provenance).

  ## Examples

      <.intake_source_tag source_key="landing-page" />
  """
  attr :source_key, :string, required: true

  def intake_source_tag(assigns) do
    ~H"""
    <span
      class="text-xs px-1.5 py-0.5 rounded font-mono text-gray-600 dark:text-zinc-300 bg-gray-100 dark:bg-zinc-700"
      data-testid="intake-source-tag"
    >
      {@source_key}
    </span>
    """
  end

  @doc """
  Renders an amber badge flagging a public-intake conversation with no reply
  channel (no linked contact email and no captured prospect email).

  A badge, never a filter — flagged conversations stay fully visible in the
  attention queue.

  ## Examples

      <.no_reply_channel_badge />
  """
  def no_reply_channel_badge(assigns) do
    ~H"""
    <span
      class="text-xs px-1.5 py-0.5 rounded text-amber-700 dark:text-amber-300 bg-amber-50 dark:bg-amber-950"
      data-testid="no-reply-channel-badge"
    >
      No reply channel
    </span>
    """
  end

  @doc """
  Renders a webhook purpose toggle switch.

  ## Examples

      <.webhook_purpose_toggle purpose={:sender_matching} enabled={true} route_id={1} />
  """
  attr :purpose, :atom, required: true
  attr :enabled, :boolean, required: true
  attr :route_id, :integer, required: true
  attr :disabled, :boolean, default: false

  def webhook_purpose_toggle(assigns) do
    ~H"""
    <div class="flex items-center justify-between py-1" data-testid={"webhook-toggle-#{@purpose}"}>
      <span class="text-sm text-gray-700 dark:text-zinc-300 capitalize">
        {to_string(@purpose) |> String.replace("_", " ")}
      </span>
      <button
        type="button"
        phx-click="toggle_webhook"
        phx-value-route-id={@route_id}
        phx-value-purpose={@purpose}
        phx-value-enabled={to_string(!@enabled)}
        disabled={@disabled}
        class={[
          "relative inline-flex h-5 w-9 shrink-0 cursor-pointer rounded-full border-2 border-transparent transition-colors duration-200",
          if(@enabled, do: "bg-indigo-600", else: "bg-gray-200 dark:bg-zinc-600"),
          if(@disabled, do: "opacity-50 cursor-not-allowed", else: "")
        ]}
        data-testid={"webhook-toggle-btn-#{@purpose}"}
      >
        <span class={[
          "pointer-events-none inline-block h-4 w-4 rounded-full bg-white shadow transform transition-transform duration-200",
          if(@enabled, do: "translate-x-4", else: "translate-x-0")
        ]} />
      </button>
    </div>
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
