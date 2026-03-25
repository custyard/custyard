defmodule CustyardWeb.Operator.SettingsLive do
  use CustyardWeb, :live_view

  alias Custyard.Settings

  @impl true
  def mount(_params, _session, socket) do
    settings = Settings.get()

    weights = settings.score_weights
    thresholds = settings.neglect_thresholds

    socket =
      socket
      |> assign(:weights, weights)
      |> assign(:thresholds, thresholds)
      |> assign(:editing_weights, false)
      |> assign(:editing_thresholds, false)
      |> assign(:weight_form, to_form(weights, as: "weights"))
      |> assign(:threshold_form, to_form(flatten_thresholds(thresholds), as: "thresholds"))

    {:ok, socket, layout: {CustyardWeb.Layouts, :operator}}
  end

  @impl true
  def handle_event("edit_weights", _params, socket) do
    {:noreply, assign(socket, :editing_weights, true)}
  end

  @impl true
  def handle_event("cancel_weights", _params, socket) do
    {:noreply, assign(socket, :editing_weights, false)}
  end

  @impl true
  def handle_event("save_weights", %{"weights" => weight_params}, socket) do
    weights =
      weight_params
      |> Enum.map(fn {k, v} -> {k, parse_float(v)} end)
      |> Map.new()

    case Settings.update_weights(weights) do
      {:ok, _settings} ->
        {:noreply,
         socket
         |> assign(:weights, weights)
         |> assign(:editing_weights, false)
         |> assign(:weight_form, to_form(weights, as: "weights"))
         |> put_flash(:info, "Weights updated successfully")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to update weights")}
    end
  end

  @impl true
  def handle_event("edit_thresholds", _params, socket) do
    {:noreply, assign(socket, :editing_thresholds, true)}
  end

  @impl true
  def handle_event("cancel_thresholds", _params, socket) do
    {:noreply, assign(socket, :editing_thresholds, false)}
  end

  @impl true
  def handle_event("save_thresholds", %{"thresholds" => threshold_params}, socket) do
    thresholds =
      %{
        "enterprise" => [
          parse_int(threshold_params["enterprise_warning"]),
          parse_int(threshold_params["enterprise_critical"])
        ],
        "standard" => [
          parse_int(threshold_params["standard_warning"]),
          parse_int(threshold_params["standard_critical"])
        ],
        "basic" => [
          parse_int(threshold_params["basic_warning"]),
          parse_int(threshold_params["basic_critical"])
        ]
      }

    # Validate that warning < critical for each tier
    invalid_tiers =
      thresholds
      |> Enum.filter(fn {_tier, [warning, critical]} -> warning >= critical end)
      |> Enum.map(fn {tier, _} -> tier end)

    if invalid_tiers != [] do
      {:noreply,
       put_flash(
         socket,
         :error,
         "Warning threshold must be less than critical threshold for: #{Enum.join(invalid_tiers, ", ")}"
       )}
    else
      # Convert to tuple format for update_thresholds
      thresholds_tuples =
        thresholds
        |> Enum.map(fn {tier, [w, c]} -> {String.to_atom(tier), {w, c}} end)
        |> Map.new()

      case Settings.update_thresholds(thresholds_tuples) do
        {:ok, _settings} ->
          {:noreply,
           socket
           |> assign(:thresholds, thresholds)
           |> assign(:editing_thresholds, false)
           |> assign(:threshold_form, to_form(flatten_thresholds(thresholds), as: "thresholds"))
           |> put_flash(:info, "Thresholds updated successfully")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to update thresholds")}
      end
    end
  end

  defp parse_float(str) when is_binary(str) do
    case Float.parse(str) do
      {f, _} -> f
      :error -> 1.0
    end
  end

  defp parse_float(num) when is_number(num), do: num / 1

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {i, _} -> i
      :error -> 24
    end
  end

  defp parse_int(num) when is_integer(num), do: num

  defp flatten_thresholds(thresholds) do
    Enum.reduce(thresholds, %{}, fn {tier, [warning, critical]}, acc ->
      acc
      |> Map.put("#{tier}_warning", warning)
      |> Map.put("#{tier}_critical", critical)
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto p-4" data-testid="operator-settings-page">
      <h1 class="text-lg font-semibold text-gray-900 mb-6" data-testid="operator-settings-heading">
        Settings
      </h1>

      <div
        class="bg-white border border-gray-200 rounded-lg p-4 mb-4"
        data-testid="operator-settings-weights"
      >
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-sm font-semibold text-gray-900">Score Weights</h2>
          <button
            :if={not @editing_weights}
            phx-click="edit_weights"
            class="text-xs text-blue-600 hover:text-blue-800"
            data-testid="operator-settings-edit-weights"
          >
            Edit
          </button>
        </div>
        <p class="text-xs text-gray-500 mb-4">
          These weights affect how conversations are ranked in the attention queue.
          Higher weights give more importance to that factor.
        </p>

        <div :if={not @editing_weights} class="space-y-3">
          <div
            :for={{key, value} <- @weights}
            class="flex items-center justify-between"
            data-testid={"operator-settings-weight-#{key}"}
          >
            <span class="text-sm text-gray-700 capitalize">{key}</span>
            <span class="text-sm font-mono text-gray-600 bg-gray-50 px-2 py-1 rounded">
              {value}
            </span>
          </div>
        </div>

        <form
          :if={@editing_weights}
          phx-submit="save_weights"
          class="space-y-3"
          data-testid="operator-settings-weights-form"
        >
          <div :for={{key, value} <- @weights} class="flex items-center justify-between">
            <label class="text-sm text-gray-700 capitalize" for={"weights_#{key}"}>{key}</label>
            <input
              type="number"
              step="0.1"
              min="0"
              max="10"
              name={"weights[#{key}]"}
              id={"weights_#{key}"}
              value={value}
              class="w-20 text-sm font-mono text-gray-600 bg-gray-50 px-2 py-1 rounded border border-gray-300 focus:ring-blue-500 focus:border-blue-500"
            />
          </div>
          <div class="flex justify-end gap-2 mt-4 pt-4 border-t border-gray-100">
            <button
              type="button"
              phx-click="cancel_weights"
              class="text-xs text-gray-600 hover:text-gray-800 px-3 py-1"
              data-testid="operator-settings-cancel-weights"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="text-xs text-white bg-blue-600 hover:bg-blue-700 px-3 py-1 rounded"
              data-testid="operator-settings-save-weights"
            >
              Save
            </button>
          </div>
        </form>
      </div>

      <div
        class="bg-white border border-gray-200 rounded-lg p-4 mb-4"
        data-testid="operator-settings-thresholds"
      >
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-sm font-semibold text-gray-900">Neglect Thresholds</h2>
          <button
            :if={not @editing_thresholds}
            phx-click="edit_thresholds"
            class="text-xs text-blue-600 hover:text-blue-800"
            data-testid="operator-settings-edit-thresholds"
          >
            Edit
          </button>
        </div>
        <p class="text-xs text-gray-500 mb-4">
          Hours without operator action before conversations are flagged.
          (warning, critical) by tier.
        </p>

        <div :if={not @editing_thresholds} class="space-y-3">
          <div
            :for={{tier, [warning, critical]} <- @thresholds}
            class="flex items-center justify-between"
            data-testid={"operator-settings-threshold-#{tier}"}
          >
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
        </div>

        <form
          :if={@editing_thresholds}
          phx-submit="save_thresholds"
          class="space-y-3"
          data-testid="operator-settings-thresholds-form"
        >
          <div
            :for={{tier, [warning, critical]} <- @thresholds}
            class="flex items-center justify-between"
          >
            <span class="text-sm text-gray-700 capitalize">{tier}</span>
            <div class="flex items-center gap-2">
              <div class="flex items-center gap-1">
                <input
                  type="number"
                  min="1"
                  name={"thresholds[#{tier}_warning]"}
                  value={warning}
                  class="w-16 text-xs text-amber-600 bg-amber-50 px-2 py-1 rounded border border-amber-200 focus:ring-amber-500 focus:border-amber-500"
                />
                <span class="text-xs text-gray-500">h</span>
              </div>
              <div class="flex items-center gap-1">
                <input
                  type="number"
                  min="1"
                  name={"thresholds[#{tier}_critical]"}
                  value={critical}
                  class="w-16 text-xs text-red-600 bg-red-50 px-2 py-1 rounded border border-red-200 focus:ring-red-500 focus:border-red-500"
                />
                <span class="text-xs text-gray-500">h</span>
              </div>
            </div>
          </div>
          <div class="flex justify-end gap-2 mt-4 pt-4 border-t border-gray-100">
            <button
              type="button"
              phx-click="cancel_thresholds"
              class="text-xs text-gray-600 hover:text-gray-800 px-3 py-1"
              data-testid="operator-settings-cancel-thresholds"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="text-xs text-white bg-blue-600 hover:bg-blue-700 px-3 py-1 rounded"
              data-testid="operator-settings-save-thresholds"
            >
              Save
            </button>
          </div>
        </form>
      </div>

      <div
        class="bg-white border border-gray-200 rounded-lg p-4"
        data-testid="operator-settings-score-calc"
      >
        <h2 class="text-sm font-semibold text-gray-900 mb-4">Score Calculation</h2>
        <p class="text-xs text-gray-500 mb-2">
          The attention score is calculated as:
        </p>
        <pre
          class="text-xs text-gray-600 bg-gray-50 p-3 rounded overflow-x-auto"
          data-testid="operator-settings-formula"
        >
          Score = (idle_weight * idle_score) +
                  (state_weight * state_score) +
                  (tier_weight * tier_score) +
                  (urgency_weight * urgency_score) +
                  (velocity_weight * velocity_score) +
                  (neglect_weight * neglect_bonus)
        </pre>

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
