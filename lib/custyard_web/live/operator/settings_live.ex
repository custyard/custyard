defmodule CustyardWeb.Operator.SettingsLive do
  use CustyardWeb, :live_view

  import CustyardWeb.FormHelpers, only: [format_changeset_errors: 1]

  alias Custyard.{Authorization, Settings}
  alias CustyardWeb.Uploads

  # Fixed display order for weight keys (maps don't guarantee iteration order)
  @weight_display_order ~w(idle state tier urgency velocity neglect)a

  @impl true
  def mount(_params, _session, socket) do
    settings = Settings.get()

    weights = settings.score_weights
    thresholds = settings.neglect_thresholds
    branding = Settings.get_branding()

    socket =
      socket
      |> assign(:page_title, "Settings")
      |> assign(:weights, weights)
      |> assign(:thresholds, thresholds)
      |> assign(:intake_config, Settings.get_intake_config())
      |> assign(:branding, branding)
      |> assign(:editing_weights, false)
      |> assign(:editing_thresholds, false)
      |> assign(:editing_intake, false)
      |> assign(:editing_branding, false)
      |> assign(:weight_form, to_form(weights, as: "weights"))
      |> assign(:threshold_form, to_form(flatten_thresholds(thresholds), as: "thresholds"))
      |> assign(:branding_form, branding_form_from(branding))
      |> allow_upload(:logo,
        accept: ~w(.png .jpg .jpeg .svg .webp),
        max_entries: 1,
        max_file_size: 2_000_000
      )

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
    if Authorization.can_modify_settings?(socket.assigns.current_operator) do
      do_save_weights(weight_params, socket)
    else
      {:noreply, put_flash(socket, :error, "Only super admins can modify settings")}
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
    if Authorization.can_modify_settings?(socket.assigns.current_operator) do
      save_thresholds(threshold_params, socket)
    else
      {:noreply, put_flash(socket, :error, "Only super admins can modify settings")}
    end
  end

  @impl true
  def handle_event("edit_intake", _params, socket) do
    {:noreply, assign(socket, :editing_intake, true)}
  end

  @impl true
  def handle_event("cancel_intake", _params, socket) do
    {:noreply, assign(socket, :editing_intake, false)}
  end

  @impl true
  def handle_event("save_intake", %{"intake" => intake_params}, socket) do
    if Authorization.can_modify_settings?(socket.assigns.current_operator) do
      save_intake(intake_params, socket)
    else
      {:noreply, put_flash(socket, :error, "Only super admins can modify settings")}
    end
  end

  @impl true
  def handle_event("edit_branding", _params, socket) do
    {:noreply,
     socket
     |> assign(:editing_branding, true)
     |> assign(:branding_form, branding_form_from(socket.assigns.branding))}
  end

  @impl true
  def handle_event("cancel_branding", _params, socket) do
    socket =
      Enum.reduce(socket.assigns.uploads.logo.entries, socket, fn entry, acc ->
        cancel_upload(acc, :logo, entry.ref)
      end)

    {:noreply, assign(socket, :editing_branding, false)}
  end

  # Tracks in-progress branding form state so re-renders triggered by upload
  # progress (or the color picker) don't reset what the operator has typed.
  @impl true
  def handle_event("validate_branding", params, socket) do
    branding_params = Map.get(params, "branding", %{})
    form = socket.assigns.branding_form

    form =
      form
      |> Map.put("name", Map.get(branding_params, "name", form["name"]))
      |> Map.put(
        "primary_color",
        Map.get(branding_params, "primary_color", form["primary_color"])
      )
      |> Map.put("remove_logo", Map.get(branding_params, "remove_logo", "false") == "true")

    # The native color picker feeds the visible hex input, not vice versa.
    form =
      case params["_target"] do
        ["branding", "primary_color_picker"] ->
          Map.put(form, "primary_color", Map.get(branding_params, "primary_color_picker", ""))

        _ ->
          form
      end

    {:noreply, assign(socket, :branding_form, form)}
  end

  @impl true
  def handle_event("cancel_logo_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :logo, ref)}
  end

  @impl true
  def handle_event("save_branding", %{"branding" => branding_params}, socket) do
    if Authorization.can_modify_settings?(socket.assigns.current_operator) do
      save_branding(branding_params, socket)
    else
      {:noreply, put_flash(socket, :error, "Only super admins can modify settings")}
    end
  end

  defp do_save_weights(weight_params, socket) do
    parsed =
      weight_params
      |> Enum.map(fn {k, v} -> {k, parse_float(v)} end)

    invalid_keys =
      parsed
      |> Enum.filter(fn {_k, v} -> v == :error end)
      |> Enum.map(fn {k, _} -> k end)

    if invalid_keys != [] do
      {:noreply,
       put_flash(socket, :error, "Invalid numeric values for: #{Enum.join(invalid_keys, ", ")}")}
    else
      weights = Map.new(parsed)

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
  end

  defp save_thresholds(threshold_params, socket) do
    parsed_values = [
      {"enterprise_warning", parse_int(threshold_params["enterprise_warning"])},
      {"enterprise_critical", parse_int(threshold_params["enterprise_critical"])},
      {"standard_warning", parse_int(threshold_params["standard_warning"])},
      {"standard_critical", parse_int(threshold_params["standard_critical"])},
      {"basic_warning", parse_int(threshold_params["basic_warning"])},
      {"basic_critical", parse_int(threshold_params["basic_critical"])}
    ]

    invalid_fields =
      parsed_values
      |> Enum.filter(fn {_k, v} -> v == :error end)
      |> Enum.map(fn {k, _} -> k end)

    if invalid_fields != [] do
      {:noreply,
       put_flash(socket, :error, "Invalid numeric values for: #{Enum.join(invalid_fields, ", ")}")}
    else
      values = Map.new(parsed_values)

      thresholds =
        %{
          "enterprise" => [values["enterprise_warning"], values["enterprise_critical"]],
          "standard" => [values["standard_warning"], values["standard_critical"]],
          "basic" => [values["basic_warning"], values["basic_critical"]]
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
          |> Enum.map(fn {tier, [w, c]} -> {String.to_existing_atom(tier), {w, c}} end)
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
  end

  defp save_intake(intake_params, socket) do
    parsed_values = [
      {"unlinked_tier_score", parse_int(intake_params["unlinked_tier_score"])},
      {"slug_claim_ttl_hours", parse_int(intake_params["slug_claim_ttl_hours"])}
    ]

    invalid_fields =
      parsed_values
      |> Enum.filter(fn {_k, v} -> v == :error end)
      |> Enum.map(fn {k, _} -> k end)

    if invalid_fields != [] do
      {:noreply,
       put_flash(socket, :error, "Invalid numeric values for: #{Enum.join(invalid_fields, ", ")}")}
    else
      config = Map.new(parsed_values)

      case Settings.update_intake_config(config) do
        {:ok, _settings} ->
          {:noreply,
           socket
           |> assign(:intake_config, Settings.get_intake_config())
           |> assign(:editing_intake, false)
           |> put_flash(:info, "Intake settings updated successfully")}

        {:error, _changeset} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             "Failed to update intake settings. Unlinked tier score must be 0-100 and slug claim TTL must be 1-720 hours."
           )}
      end
    end
  end

  # Blank (empty or whitespace-only) fields are omitted rather than stored:
  # update_branding replaces the whole map, so an omitted key reads back as
  # its default (nil). Settings.valid_branding_entry?/2 independently rejects
  # blank names, so direct context callers cannot store them either.
  #
  # The logo never comes from a form param - it is either a freshly consumed
  # upload, the previously stored path, or nil when "remove_logo" is checked.
  defp save_branding(branding_params, socket) do
    old_logo_url = socket.assigns.branding.logo_url
    uploaded_logo_url = consume_uploaded_logo(socket)
    remove_logo? = Map.get(branding_params, "remove_logo") == "true"

    logo_url =
      cond do
        uploaded_logo_url -> uploaded_logo_url
        remove_logo? -> nil
        true -> old_logo_url
      end

    branding =
      branding_params
      |> Map.take(["name", "primary_color"])
      |> Map.put("logo_url", logo_url)
      |> Enum.reject(fn {_key, value} ->
        not is_binary(value) or String.trim(value) == ""
      end)
      |> Map.new()

    case Settings.update_branding(branding) do
      {:ok, _settings} ->
        # Delete the replaced (or explicitly removed) file only after the new
        # branding persisted successfully.
        if old_logo_url && old_logo_url != logo_url do
          Uploads.delete_logo(old_logo_url)
        end

        {:noreply,
         socket
         |> assign(:branding, Settings.get_branding())
         |> assign(:editing_branding, false)
         |> put_flash(:info, "Branding updated successfully")}

      {:error, changeset} ->
        # The consumed upload was never persisted; remove it so failed saves
        # (e.g. a bad color) don't leave orphaned files behind.
        if uploaded_logo_url, do: Uploads.delete_logo(uploaded_logo_url)

        {:noreply,
         put_flash(
           socket,
           :error,
           "Failed to update branding: #{format_changeset_errors(changeset)}"
         )}
    end
  end

  defp consume_uploaded_logo(socket) do
    socket
    |> consume_uploaded_entries(:logo, fn %{path: path}, entry ->
      {:ok, Uploads.save_logo(path, entry.client_name)}
    end)
    |> List.first()
  end

  defp branding_form_from(branding) do
    %{
      "name" => branding.name || "",
      "primary_color" => branding.primary_color || "",
      "remove_logo" => false
    }
  end

  defp upload_error_to_string(:too_large), do: "File is too large (max 2MB)"
  defp upload_error_to_string(:not_accepted), do: "Invalid file type"
  defp upload_error_to_string(:too_many_files), do: "Only one file allowed"
  defp upload_error_to_string(_), do: "Upload error"

  defp parse_float(str) when is_binary(str) do
    case Float.parse(str) do
      {f, _} -> f
      :error -> :error
    end
  end

  defp parse_float(num) when is_number(num), do: num / 1
  defp parse_float(_), do: :error

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {i, _} -> i
      :error -> :error
    end
  end

  defp parse_int(num) when is_integer(num), do: num
  defp parse_int(_), do: :error

  defp flatten_thresholds(thresholds) do
    Enum.reduce(thresholds, %{}, fn {tier, [warning, critical]}, acc ->
      acc
      |> Map.put("#{tier}_warning", warning)
      |> Map.put("#{tier}_critical", critical)
    end)
  end

  # Sort weights according to fixed display order
  defp sorted_weights(weights) do
    @weight_display_order
    |> Enum.filter(&Map.has_key?(weights, &1))
    |> Enum.map(&{&1, Map.get(weights, &1)})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto p-4" data-testid="operator-settings-page">
      <h1
        class="text-lg font-semibold text-gray-900 dark:text-zinc-100 mb-6"
        data-testid="operator-settings-heading"
      >
        Settings
      </h1>

      <div
        class="bg-white dark:bg-zinc-800 border border-gray-200 dark:border-zinc-700 rounded-lg p-4 mb-4"
        data-testid="operator-settings-weights"
      >
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-sm font-semibold text-gray-900 dark:text-zinc-100">Score Weights</h2>
          <button
            :if={not @editing_weights}
            phx-click="edit_weights"
            class="text-xs text-blue-600 hover:text-blue-800"
            data-testid="operator-settings-edit-weights"
          >
            Edit
          </button>
        </div>
        <p class="text-xs text-gray-500 dark:text-zinc-400 mb-4">
          These weights affect how conversations are ranked in the attention queue.
          Higher weights give more importance to that factor.
        </p>

        <div :if={not @editing_weights} class="space-y-3">
          <div
            :for={{key, value} <- sorted_weights(@weights)}
            class="flex items-center justify-between"
            data-testid={"operator-settings-weight-#{key}"}
          >
            <span class="text-sm text-gray-700 dark:text-zinc-300 capitalize">{key}</span>
            <span class="text-sm font-mono text-gray-600 dark:text-zinc-400 bg-gray-50 dark:bg-zinc-800 px-2 py-1 rounded">
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
          <div
            :for={{key, value} <- sorted_weights(@weights)}
            class="flex items-center justify-between"
          >
            <label class="text-sm text-gray-700 dark:text-zinc-300 capitalize" for={"weights_#{key}"}>
              {key}
            </label>
            <input
              type="number"
              step="0.1"
              min="0"
              max="10"
              name={"weights[#{key}]"}
              id={"weights_#{key}"}
              value={value}
              class="w-20 text-sm font-mono text-gray-600 dark:text-zinc-400 bg-gray-50 dark:bg-zinc-800 px-2 py-1 rounded border border-gray-300 dark:border-zinc-600 focus:ring-blue-500 focus:border-blue-500"
            />
          </div>
          <div class="flex justify-end gap-2 mt-4 pt-4 border-t border-gray-100 dark:border-zinc-700">
            <button
              type="button"
              phx-click="cancel_weights"
              class="text-xs text-gray-600 dark:text-zinc-400 hover:text-gray-800 dark:hover:text-zinc-200 px-3 py-1"
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
        class="bg-white dark:bg-zinc-800 border border-gray-200 dark:border-zinc-700 rounded-lg p-4 mb-4"
        data-testid="operator-settings-thresholds"
      >
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-sm font-semibold text-gray-900 dark:text-zinc-100">Neglect Thresholds</h2>
          <button
            :if={not @editing_thresholds}
            phx-click="edit_thresholds"
            class="text-xs text-blue-600 hover:text-blue-800"
            data-testid="operator-settings-edit-thresholds"
          >
            Edit
          </button>
        </div>
        <p class="text-xs text-gray-500 dark:text-zinc-400 mb-4">
          Hours without operator action before conversations are flagged.
          (warning, critical) by tier.
        </p>

        <div :if={not @editing_thresholds} class="space-y-3">
          <div
            :for={{tier, [warning, critical]} <- @thresholds}
            class="flex items-center justify-between"
            data-testid={"operator-settings-threshold-#{tier}"}
          >
            <span class="text-sm text-gray-700 dark:text-zinc-300 capitalize">{tier}</span>
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
            <span
              class="text-sm text-gray-700 dark:text-zinc-300 capitalize"
              id={"thresholds-#{tier}-label"}
            >
              {tier}
            </span>
            <div class="flex items-center gap-2">
              <div class="flex items-center gap-1">
                <label for={"thresholds_#{tier}_warning"} class="sr-only">
                  {tier} warning threshold (hours)
                </label>
                <input
                  type="number"
                  min="1"
                  id={"thresholds_#{tier}_warning"}
                  name={"thresholds[#{tier}_warning]"}
                  value={warning}
                  class="w-16 text-xs text-amber-600 bg-amber-50 px-2 py-1 rounded border border-amber-200 focus:ring-amber-500 focus:border-amber-500"
                />
                <span class="text-xs text-gray-500 dark:text-zinc-400">h</span>
              </div>
              <div class="flex items-center gap-1">
                <label for={"thresholds_#{tier}_critical"} class="sr-only">
                  {tier} critical threshold (hours)
                </label>
                <input
                  type="number"
                  min="1"
                  id={"thresholds_#{tier}_critical"}
                  name={"thresholds[#{tier}_critical]"}
                  value={critical}
                  class="w-16 text-xs text-red-600 bg-red-50 px-2 py-1 rounded border border-red-200 focus:ring-red-500 focus:border-red-500"
                />
                <span class="text-xs text-gray-500 dark:text-zinc-400">h</span>
              </div>
            </div>
          </div>
          <div class="flex justify-end gap-2 mt-4 pt-4 border-t border-gray-100 dark:border-zinc-700">
            <button
              type="button"
              phx-click="cancel_thresholds"
              class="text-xs text-gray-600 dark:text-zinc-400 hover:text-gray-800 dark:hover:text-zinc-200 px-3 py-1"
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
        class="bg-white dark:bg-zinc-800 border border-gray-200 dark:border-zinc-700 rounded-lg p-4 mb-4"
        data-testid="operator-settings-intake"
      >
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-sm font-semibold text-gray-900 dark:text-zinc-100">Intake</h2>
          <button
            :if={not @editing_intake}
            phx-click="edit_intake"
            class="text-xs text-blue-600 hover:text-blue-800"
            data-testid="operator-settings-edit-intake"
          >
            Edit
          </button>
        </div>
        <p class="text-xs text-gray-500 dark:text-zinc-400 mb-4">
          Public intake behavior. The unlinked tier score is the tier-equivalent score
          for conversations without an organization (0-100). The slug claim TTL is how
          long an unconfirmed slug claim lives (1-720 hours).
        </p>

        <div :if={not @editing_intake} class="space-y-3">
          <div
            class="flex items-center justify-between"
            data-testid="operator-settings-intake-unlinked-tier-score"
          >
            <span class="text-sm text-gray-700 dark:text-zinc-300">Unlinked tier score</span>
            <span class="text-sm font-mono text-gray-600 dark:text-zinc-400 bg-gray-50 dark:bg-zinc-800 px-2 py-1 rounded">
              {@intake_config.unlinked_tier_score}
            </span>
          </div>
          <div
            class="flex items-center justify-between"
            data-testid="operator-settings-intake-slug-claim-ttl"
          >
            <span class="text-sm text-gray-700 dark:text-zinc-300">Slug claim TTL (hours)</span>
            <span class="text-sm font-mono text-gray-600 dark:text-zinc-400 bg-gray-50 dark:bg-zinc-800 px-2 py-1 rounded">
              {@intake_config.slug_claim_ttl_hours}
            </span>
          </div>
        </div>

        <form
          :if={@editing_intake}
          phx-submit="save_intake"
          class="space-y-3"
          data-testid="operator-settings-intake-form"
        >
          <div class="flex items-center justify-between">
            <label
              class="text-sm text-gray-700 dark:text-zinc-300"
              for="intake_unlinked_tier_score"
            >
              Unlinked tier score
            </label>
            <input
              type="number"
              min="0"
              max="100"
              name="intake[unlinked_tier_score]"
              id="intake_unlinked_tier_score"
              value={@intake_config.unlinked_tier_score}
              class="w-20 text-sm font-mono text-gray-600 dark:text-zinc-400 bg-gray-50 dark:bg-zinc-800 px-2 py-1 rounded border border-gray-300 dark:border-zinc-600 focus:ring-blue-500 focus:border-blue-500"
            />
          </div>
          <div class="flex items-center justify-between">
            <label
              class="text-sm text-gray-700 dark:text-zinc-300"
              for="intake_slug_claim_ttl_hours"
            >
              Slug claim TTL (hours)
            </label>
            <input
              type="number"
              min="1"
              max="720"
              name="intake[slug_claim_ttl_hours]"
              id="intake_slug_claim_ttl_hours"
              value={@intake_config.slug_claim_ttl_hours}
              class="w-20 text-sm font-mono text-gray-600 dark:text-zinc-400 bg-gray-50 dark:bg-zinc-800 px-2 py-1 rounded border border-gray-300 dark:border-zinc-600 focus:ring-blue-500 focus:border-blue-500"
            />
          </div>
          <div class="flex justify-end gap-2 mt-4 pt-4 border-t border-gray-100 dark:border-zinc-700">
            <button
              type="button"
              phx-click="cancel_intake"
              class="text-xs text-gray-600 dark:text-zinc-400 hover:text-gray-800 dark:hover:text-zinc-200 px-3 py-1"
              data-testid="operator-settings-cancel-intake"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="text-xs text-white bg-blue-600 hover:bg-blue-700 px-3 py-1 rounded"
              data-testid="operator-settings-save-intake"
            >
              Save
            </button>
          </div>
        </form>
      </div>

      <div
        class="bg-white dark:bg-zinc-800 border border-gray-200 dark:border-zinc-700 rounded-lg p-4 mb-4"
        data-testid="operator-settings-branding"
      >
        <div class="flex items-center justify-between mb-4">
          <h2 class="text-sm font-semibold text-gray-900 dark:text-zinc-100">Branding</h2>
          <button
            :if={not @editing_branding}
            phx-click="edit_branding"
            class="text-xs text-blue-600 hover:text-blue-800"
            data-testid="operator-settings-edit-branding"
          >
            Edit
          </button>
        </div>
        <p class="text-xs text-gray-500 dark:text-zinc-400 mb-4">
          Instance branding for the public intake pages and prospect-facing email.
          The name falls back to "Custyard" when unset. Upload a logo image
          (PNG, JPG, SVG, or WebP, max 2MB) and pick a primary color. Leave the
          name or color blank to clear it.
        </p>

        <div :if={not @editing_branding} class="space-y-3">
          <div
            class="flex items-center justify-between"
            data-testid="operator-settings-branding-name"
          >
            <span class="text-sm text-gray-700 dark:text-zinc-300">Name</span>
            <span class="text-sm font-mono text-gray-600 dark:text-zinc-400 bg-gray-50 dark:bg-zinc-800 px-2 py-1 rounded">
              {@branding.name || "not set"}
            </span>
          </div>
          <div
            class="flex items-center justify-between"
            data-testid="operator-settings-branding-logo-url"
          >
            <span class="text-sm text-gray-700 dark:text-zinc-300">Logo</span>
            <span class="flex items-center gap-2">
              <img
                :if={@branding.logo_url}
                src={@branding.logo_url}
                alt="Instance logo"
                class="w-8 h-8 rounded object-cover border border-gray-200 dark:border-zinc-700"
                data-testid="operator-settings-branding-logo-thumb"
              />
              <span class="text-sm font-mono text-gray-600 dark:text-zinc-400 bg-gray-50 dark:bg-zinc-800 px-2 py-1 rounded break-all">
                {@branding.logo_url || "not set"}
              </span>
            </span>
          </div>
          <div
            class="flex items-center justify-between"
            data-testid="operator-settings-branding-primary-color"
          >
            <span class="text-sm text-gray-700 dark:text-zinc-300">Primary color</span>
            <span class="flex items-center gap-2">
              <span
                :if={@branding.primary_color}
                class="inline-block w-4 h-4 rounded border border-gray-300 dark:border-zinc-600"
                style={"background-color: #{@branding.primary_color}"}
              />
              <span class="text-sm font-mono text-gray-600 dark:text-zinc-400 bg-gray-50 dark:bg-zinc-800 px-2 py-1 rounded">
                {@branding.primary_color || "not set"}
              </span>
            </span>
          </div>
        </div>

        <form
          :if={@editing_branding}
          phx-submit="save_branding"
          phx-change="validate_branding"
          class="space-y-3"
          data-testid="operator-settings-branding-form"
        >
          <div class="flex items-center justify-between gap-4">
            <label class="text-sm text-gray-700 dark:text-zinc-300" for="branding_name">
              Name
            </label>
            <input
              type="text"
              maxlength="100"
              name="branding[name]"
              id="branding_name"
              value={@branding_form["name"]}
              placeholder="Custyard (default)"
              phx-debounce="300"
              class="w-64 text-sm font-mono text-gray-600 dark:text-zinc-400 bg-gray-50 dark:bg-zinc-800 px-2 py-1 rounded border border-gray-300 dark:border-zinc-600 focus:ring-blue-500 focus:border-blue-500"
            />
          </div>
          <div>
            <label
              class="block text-sm text-gray-700 dark:text-zinc-300 mb-1"
              for={@uploads.logo.ref}
            >
              Logo
            </label>
            <div class="flex items-start gap-4">
              <div :if={@branding.logo_url} class="shrink-0">
                <img
                  src={@branding.logo_url}
                  alt="Current logo"
                  class="w-16 h-16 rounded object-cover border border-gray-200 dark:border-zinc-700"
                  data-testid="operator-settings-branding-current-logo"
                />
                <label class="flex items-center gap-1 mt-1 text-xs text-gray-500 dark:text-zinc-400">
                  <input type="hidden" name="branding[remove_logo]" value="false" />
                  <input
                    type="checkbox"
                    name="branding[remove_logo]"
                    value="true"
                    checked={@branding_form["remove_logo"]}
                    class="rounded border-gray-300 dark:border-zinc-600"
                    data-testid="operator-settings-branding-remove-logo"
                  /> Remove logo
                </label>
              </div>
              <div class="flex-1">
                <.live_file_input upload={@uploads.logo} class="text-sm" />
                <p class="text-xs text-gray-500 dark:text-zinc-400 mt-1">
                  PNG, JPG, SVG, or WebP. Max 2MB.
                </p>
                <div :for={entry <- @uploads.logo.entries} class="mt-2">
                  <div class="flex items-center gap-2">
                    <div class="text-sm text-gray-600 dark:text-zinc-400">{entry.client_name}</div>
                    <progress value={entry.progress} max="100" class="w-20 h-2" />
                    <button
                      type="button"
                      phx-click="cancel_logo_upload"
                      phx-value-ref={entry.ref}
                      class="text-red-500 text-xs hover:text-red-700"
                    >
                      Cancel
                    </button>
                  </div>
                  <div
                    :for={err <- upload_errors(@uploads.logo, entry)}
                    class="text-red-500 text-xs mt-1"
                  >
                    {upload_error_to_string(err)}
                  </div>
                </div>
                <div :for={err <- upload_errors(@uploads.logo)} class="text-red-500 text-xs mt-1">
                  {upload_error_to_string(err)}
                </div>
              </div>
            </div>
          </div>
          <div class="flex items-center justify-between gap-4">
            <label class="text-sm text-gray-700 dark:text-zinc-300" for="branding_primary_color">
              Primary color
            </label>
            <div class="flex items-center gap-2">
              <input
                type="color"
                name="branding[primary_color_picker]"
                id="branding_primary_color_picker"
                aria-label="Primary color picker"
                value={
                  if(@branding_form["primary_color"] != "",
                    do: @branding_form["primary_color"],
                    else: "#808080"
                  )
                }
                class={[
                  "w-9 h-9 rounded border cursor-pointer",
                  if(@branding_form["primary_color"] == "",
                    do: "border-dashed border-gray-400 dark:border-zinc-500 opacity-50",
                    else: "border-gray-300 dark:border-zinc-600"
                  )
                ]}
                data-testid="operator-settings-branding-color-picker"
              />
              <input
                type="text"
                name="branding[primary_color]"
                id="branding_primary_color"
                value={@branding_form["primary_color"]}
                placeholder="#1a2b3c"
                pattern="^#[0-9a-fA-F]{6}$"
                phx-debounce="300"
                class="w-28 text-sm font-mono text-gray-600 dark:text-zinc-400 bg-gray-50 dark:bg-zinc-800 px-2 py-1 rounded border border-gray-300 dark:border-zinc-600 focus:ring-blue-500 focus:border-blue-500"
                data-testid="operator-settings-branding-color-input"
              />
            </div>
          </div>
          <div class="flex justify-end gap-2 mt-4 pt-4 border-t border-gray-100 dark:border-zinc-700">
            <button
              type="button"
              phx-click="cancel_branding"
              class="text-xs text-gray-600 dark:text-zinc-400 hover:text-gray-800 dark:hover:text-zinc-200 px-3 py-1"
              data-testid="operator-settings-cancel-branding"
            >
              Cancel
            </button>
            <button
              type="submit"
              class="text-xs text-white bg-blue-600 hover:bg-blue-700 px-3 py-1 rounded"
              data-testid="operator-settings-save-branding"
            >
              Save
            </button>
          </div>
        </form>
      </div>

      <div
        class="bg-white dark:bg-zinc-800 border border-gray-200 dark:border-zinc-700 rounded-lg p-4"
        data-testid="operator-settings-score-calc"
      >
        <button
          type="button"
          phx-click={
            JS.toggle(to: "#score-calc-details")
            |> JS.toggle(to: "#score-calc-chevron-down")
            |> JS.toggle(to: "#score-calc-chevron-up")
          }
          class="w-full flex items-center justify-between text-left"
          aria-expanded="false"
          aria-controls="score-calc-details"
          data-testid="operator-settings-score-calc-toggle"
        >
          <div>
            <h2 class="text-sm font-semibold text-gray-900 dark:text-zinc-100">Score Calculation</h2>
            <p class="text-xs text-gray-500 dark:text-zinc-400 mt-1">
              Weighted sum of idle, state, tier, urgency, velocity, and neglect factors
            </p>
          </div>
          <svg
            id="score-calc-chevron-down"
            class="h-5 w-5 text-gray-400 dark:text-zinc-500 flex-shrink-0"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
          >
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M19 9l-7 7-7-7" />
          </svg>
          <svg
            id="score-calc-chevron-up"
            class="hidden h-5 w-5 text-gray-400 dark:text-zinc-500 flex-shrink-0"
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
          >
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M5 15l7-7 7 7" />
          </svg>
        </button>

        <div id="score-calc-details" class="hidden mt-4">
          <p class="text-xs text-gray-500 dark:text-zinc-400 mb-2">
            The attention score is calculated as:
          </p>
          <pre
            class="text-xs text-gray-600 dark:text-zinc-400 bg-gray-50 dark:bg-zinc-900 p-3 rounded overflow-x-auto border border-gray-100 dark:border-zinc-700"
            data-testid="operator-settings-formula"
          >Score = (idle_weight * idle_score) +
        (state_weight * state_score) +
        (tier_weight * tier_score) +
        (urgency_weight * urgency_score) +
        (velocity_weight * velocity_score) +
        (neglect_weight * neglect_bonus)</pre>

          <div class="mt-4 space-y-2 text-xs text-gray-500 dark:text-zinc-400">
            <div>
              <strong class="text-gray-700 dark:text-zinc-300">idle_score:</strong>
              ln(hours + 1) * 10, capped at 40
            </div>
            <div>
              <strong class="text-gray-700 dark:text-zinc-300">state_score:</strong>
              new=30, dormant=25, active=15, waiting/resolved=0
            </div>
            <div>
              <strong class="text-gray-700 dark:text-zinc-300">tier_score:</strong>
              enterprise=20, standard=10, basic=5
            </div>
            <div>
              <strong class="text-gray-700 dark:text-zinc-300">urgency_score:</strong>
              urgent=15, elevated=7, normal=0
            </div>
            <div>
              <strong class="text-gray-700 dark:text-zinc-300">velocity_score:</strong>
              ln(messages_24h + 1) * 3, capped at 10
            </div>
            <div>
              <strong class="text-gray-700 dark:text-zinc-300">neglect_bonus:</strong>
              critical=15, warning=7, ok=0
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
