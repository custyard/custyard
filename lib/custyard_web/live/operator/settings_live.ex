defmodule CustyardWeb.Operator.SettingsLive do
  use CustyardWeb, :live_view

  @impl true
  def mount(_params, _session, socket) do
    # Current default weights from Scoring module
    weights = %{
      idle: 1.0,
      state: 1.0,
      tier: 1.0,
      urgency: 1.0,
      velocity: 1.0,
      neglect: 1.0
    }

    # Neglect thresholds
    thresholds = %{
      enterprise: {4, 8},
      standard: {24, 48},
      basic: {48, 72}
    }

    socket =
      socket
      |> assign(:weights, weights)
      |> assign(:thresholds, thresholds)

    {:ok, socket, layout: {CustyardWeb.Layouts, :operator}}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto p-4">
      <h1 class="text-lg font-semibold text-gray-900 mb-6">Settings</h1>

      <div class="bg-white border border-gray-200 rounded-lg p-4 mb-4">
        <h2 class="text-sm font-semibold text-gray-900 mb-4">Score Weights</h2>
        <p class="text-xs text-gray-500 mb-4">
          These weights affect how conversations are ranked in the attention queue.
          Higher weights give more importance to that factor.
        </p>

        <div class="space-y-3">
          <%= for {key, value} <- @weights do %>
            <div class="flex items-center justify-between">
              <span class="text-sm text-gray-700 capitalize">{key}</span>
              <span class="text-sm font-mono text-gray-600 bg-gray-50 px-2 py-1 rounded">
                {value}
              </span>
            </div>
          <% end %>
        </div>

        <div class="mt-4 pt-4 border-t border-gray-100">
          <p class="text-xs text-gray-400">
            Weight editing coming in a future update.
          </p>
        </div>
      </div>

      <div class="bg-white border border-gray-200 rounded-lg p-4 mb-4">
        <h2 class="text-sm font-semibold text-gray-900 mb-4">Neglect Thresholds</h2>
        <p class="text-xs text-gray-500 mb-4">
          Hours without operator action before conversations are flagged.
          (warning, critical) by tier.
        </p>

        <div class="space-y-3">
          <%= for {tier, {warning, critical}} <- @thresholds do %>
            <div class="flex items-center justify-between">
              <span class="text-sm text-gray-700 capitalize">{tier}</span>
              <div class="flex items-center gap-2">
                <span class="text-xs text-amber-600 bg-amber-50 px-2 py-1 rounded">
                  {warning}h warning
                </span>
                <span class="text-xs text-red-600 bg-red-50 px-2 py-1 rounded">
                  {critical}h critical
                </span>
              </div>
            </div>
          <% end %>
        </div>

        <div class="mt-4 pt-4 border-t border-gray-100">
          <p class="text-xs text-gray-400">
            Threshold editing coming in a future update.
          </p>
        </div>
      </div>

      <div class="bg-white border border-gray-200 rounded-lg p-4">
        <h2 class="text-sm font-semibold text-gray-900 mb-4">Score Calculation</h2>
        <p class="text-xs text-gray-500 mb-2">
          The attention score is calculated as:
        </p>
        <pre class="text-xs text-gray-600 bg-gray-50 p-3 rounded overflow-x-auto">
Score = (idle_weight * idle_score) +
        (state_weight * state_score) +
        (tier_weight * tier_score) +
        (urgency_weight * urgency_score) +
        (velocity_weight * velocity_score) +
        (neglect_weight * neglect_bonus)</pre>

        <div class="mt-4 space-y-2 text-xs text-gray-500">
          <div><strong>idle_score:</strong> ln(hours + 1) * 10, capped at 40</div>
          <div><strong>state_score:</strong> new=30, dormant=25, active=15, waiting/resolved=0</div>
          <div><strong>tier_score:</strong> enterprise=20, standard=10, basic=5</div>
          <div><strong>urgency_score:</strong> urgent=15, elevated=7, normal=0</div>
          <div><strong>velocity_score:</strong> ln(messages_24h + 1) * 3, capped at 10</div>
          <div><strong>neglect_bonus:</strong> critical=15, warning=7, ok=0</div>
        </div>
      </div>
    </div>
    """
  end
end
