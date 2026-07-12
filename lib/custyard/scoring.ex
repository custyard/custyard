defmodule Custyard.Scoring do
  @moduledoc """
  Attention score calculation for the queue ranking algorithm.

  Score = (idle_weight * idle_score) + (state_weight * state_score) +
          (tier_weight * tier_score) + (urgency_weight * urgency_score) +
          (velocity_weight * velocity_score) + (neglect_weight * neglect_bonus)

  Conversations without an organization (unlinked prospects) score with all
  components: the tier component comes from the configurable
  `intake_config.unlinked_tier_score` setting (default equal to the standard
  tier) and neglect tracking uses the standard-tier thresholds.
  """

  require Logger
  import Ecto.Query
  alias Custyard.{Conversation, Message, Repo, Settings}

  # State scores
  @state_scores %{
    new: 30,
    active: 15,
    waiting: 0,
    dormant: 25,
    resolved: 0
  }

  # Tier scores
  @tier_scores %{
    enterprise: 20,
    standard: 10,
    basic: 5
  }

  # Urgency bonuses
  @urgency_scores %{
    urgent: 15,
    elevated: 7,
    normal: 0
  }

  # Default neglect thresholds in hours {warning, critical}
  # Actual thresholds are read from Settings
  @default_neglect_thresholds %{
    enterprise: {4, 8},
    standard: {24, 48},
    basic: {48, 72}
  }

  @doc """
  Calculate and cache score for a conversation.

  Returns `{:ok, score}` on success, `{:error, reason}` on failure.
  Non-raising version to allow callers to handle errors gracefully.
  """
  def calculate_and_cache(conversation_id) do
    case Repo.get(Conversation, conversation_id) do
      nil ->
        {:error, :not_found}

      conversation ->
        conversation = Repo.preload(conversation, :organization)
        score = calculate(conversation)

        case conversation
             |> Ecto.Changeset.change(cached_score: score)
             |> Repo.update() do
          {:ok, _updated} ->
            {:ok, score}

          {:error, changeset} ->
            {:error, {:update_failed, changeset}}
        end
    end
  end

  @doc """
  Calculate and cache scores for a list of conversation IDs.
  More efficient than calling calculate_and_cache/1 in a loop as it batch-preloads
  message counts in a single query.
  """
  def calculate_and_cache_batch(conversation_ids) when is_list(conversation_ids) do
    if Enum.empty?(conversation_ids), do: :ok

    start_time = System.monotonic_time()
    batch_size = length(conversation_ids)

    # Batch load conversations with organizations
    conversations =
      from(c in Conversation,
        where: c.id in ^conversation_ids,
        preload: [:organization]
      )
      |> Repo.all()

    # Batch load message counts
    cutoff = DateTime.add(DateTime.utc_now(), -24, :hour)

    message_counts =
      from(m in Message,
        where: m.conversation_id in ^conversation_ids,
        where: m.inserted_at >= ^cutoff,
        group_by: m.conversation_id,
        select: {m.conversation_id, count(m.id)}
      )
      |> Repo.all()
      |> Map.new()

    # Calculate and update each - use non-raising update to handle race conditions
    updated_count =
      conversations
      |> Enum.map(fn conv ->
        msg_count = Map.get(message_counts, conv.id, 0)
        score = calculate_with_message_count(conv, msg_count)

        case conv
             |> Ecto.Changeset.change(cached_score: score)
             |> Repo.update() do
          {:ok, _} -> 1
          {:error, _} -> 0
        end
      end)
      |> Enum.sum()

    # Emit telemetry for batch scoring
    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:custyard, :scoring, :batch, :stop],
      %{duration: duration, count: batch_size},
      %{updated: updated_count}
    )

    updated_count
  end

  # Internal: Calculate score with pre-fetched message count (batch path)
  defp calculate_with_message_count(conversation, message_count) do
    conversation
    |> components(message_count)
    |> components_total()
  end

  defp velocity_score_from_count(count) do
    # Log scale: ln(count + 1) * 3, capped at 10
    min(10, :math.log(count + 1) * 3)
  end

  @doc """
  Calculate score without caching (for display/debugging).
  """
  def calculate(conversation) do
    conversation
    |> components(nil)
    |> components_total()
  end

  @doc """
  Get score breakdown for transparency UI.
  """
  def breakdown(conversation) do
    components = components(conversation, nil)

    %{
      idle: round(components.idle),
      state: round(components.state),
      tier: round(components.tier),
      urgency: round(components.urgency),
      velocity: round(components.velocity),
      neglect_bonus: round(components.neglect),
      total: components_total(components)
    }
  end

  # Single source of truth for the six weighted score components.
  # `message_count` overrides the 24h message-count query for the batch path;
  # pass nil to compute velocity from the database.
  defp components(conversation, message_count) do
    conversation = ensure_preloaded(conversation, :organization)
    weights = get_weights()

    velocity =
      case message_count do
        nil -> velocity_score(conversation)
        count -> velocity_score_from_count(count)
      end

    %{
      idle: idle_score(conversation) * weights.idle,
      state: state_score(conversation) * weights.state,
      tier: tier_score(conversation) * weights.tier,
      urgency: urgency_score(conversation) * weights.urgency,
      velocity: velocity * weights.velocity,
      neglect: neglect_bonus(conversation) * weights.neglect
    }
  end

  defp components_total(components) do
    components
    |> Map.values()
    |> Enum.sum()
    |> round()
  end

  @doc """
  Get neglect status for a conversation.

  Conversations without an organization (unlinked prospects) are tracked
  on the standard-tier thresholds.

  Optionally accepts pre-loaded thresholds to avoid repeated Settings lookups
  when checking multiple conversations.
  """
  def neglect_status(conversation, thresholds \\ nil)

  def neglect_status(conversation, thresholds) do
    conversation = ensure_preloaded(conversation, :organization)

    hours_idle = hours_since_operator_action(conversation)
    thresholds = thresholds || get_neglect_thresholds()
    {warning, critical} = Map.get(thresholds, neglect_tier(conversation), {24, 48})

    cond do
      hours_idle >= critical -> :critical
      hours_idle >= warning -> :warning
      true -> :ok
    end
  end

  defp neglect_tier(%{organization: nil}), do: :standard
  defp neglect_tier(conversation), do: conversation.organization.tier

  # Private functions

  defp idle_score(conversation) do
    hours = hours_since_operator_action(conversation)
    # Log scale: ln(hours + 1) * 10, capped at 40
    min(40, :math.log(hours + 1) * 10)
  end

  defp state_score(conversation) do
    Map.get(@state_scores, conversation.state, 0)
  end

  # Conversations without an organization (unlinked prospects) get the
  # configurable tier-equivalent score from intake_config.
  defp tier_score(%{organization: nil}) do
    get_unlinked_tier_score()
  end

  defp tier_score(conversation) do
    tier = conversation.organization.tier
    Map.get(@tier_scores, tier, 10)
  end

  defp urgency_score(conversation) do
    Map.get(@urgency_scores, conversation.urgency, 0)
  end

  defp velocity_score(conversation) do
    count = message_count_24h(conversation)
    # Log scale: ln(count + 1) * 3, capped at 10
    min(10, :math.log(count + 1) * 3)
  end

  defp neglect_bonus(conversation) do
    case neglect_status(conversation) do
      :critical -> 15
      :warning -> 7
      :ok -> 0
    end
  end

  defp hours_since_operator_action(conversation) do
    case conversation.last_operator_action_at do
      nil -> hours_since(conversation.inserted_at)
      dt -> hours_since(dt)
    end
  end

  defp hours_since(datetime) do
    DateTime.diff(DateTime.utc_now(), datetime, :hour)
  end

  defp message_count_24h(conversation) do
    cutoff = DateTime.add(DateTime.utc_now(), -24, :hour)

    from(m in Message,
      where: m.conversation_id == ^conversation.id,
      where: m.inserted_at >= ^cutoff,
      select: count(m.id)
    )
    |> Repo.one()
  end

  @default_weights %{idle: 1.0, state: 1.0, tier: 1.0, urgency: 1.0, velocity: 1.0, neglect: 1.0}

  defp get_weights do
    Settings.get_weights()
  rescue
    e in [Ecto.Query.CastError, Ecto.NoResultsError, ArgumentError] ->
      # Expected errors during first boot or if Settings row doesn't exist yet
      Logger.warning("Settings not available for score weights, using defaults: #{inspect(e)}")
      @default_weights

    e in [DBConnection.ConnectionError, Postgrex.Error, Exqlite.Error] ->
      # Database connectivity issues - this is more serious
      Logger.error(
        "DATABASE ERROR loading score weights, using defaults. This may indicate DB issues: #{inspect(e)}"
      )

      emit_settings_error_telemetry(:weights, e)
      @default_weights

    e ->
      # Unexpected error - log and emit telemetry for investigation
      Logger.error(
        "Unexpected error loading score weights, using defaults: #{Exception.format(:error, e)}"
      )

      emit_settings_error_telemetry(:weights, e)
      @default_weights
  end

  @default_unlinked_tier_score @tier_scores.standard

  defp get_unlinked_tier_score do
    Settings.get_intake_config().unlinked_tier_score
  rescue
    e in [Ecto.Query.CastError, Ecto.NoResultsError, ArgumentError] ->
      # Expected errors during first boot or if Settings row doesn't exist yet
      Logger.warning("Settings not available for intake config, using defaults: #{inspect(e)}")
      @default_unlinked_tier_score

    e in [DBConnection.ConnectionError, Postgrex.Error, Exqlite.Error] ->
      # Database connectivity issues - this is more serious
      Logger.error(
        "DATABASE ERROR loading intake config, using defaults. This may indicate DB issues: #{inspect(e)}"
      )

      emit_settings_error_telemetry(:intake_config, e)
      @default_unlinked_tier_score

    e ->
      # Unexpected error - log and emit telemetry for investigation
      Logger.error(
        "Unexpected error loading intake config, using defaults: #{Exception.format(:error, e)}"
      )

      emit_settings_error_telemetry(:intake_config, e)
      @default_unlinked_tier_score
  end

  defp get_neglect_thresholds do
    Settings.get_neglect_thresholds()
  rescue
    e in [Ecto.Query.CastError, Ecto.NoResultsError, ArgumentError] ->
      # Expected errors during first boot
      Logger.warning(
        "Settings not available for neglect thresholds, using defaults: #{inspect(e)}"
      )

      @default_neglect_thresholds

    e in [DBConnection.ConnectionError, Postgrex.Error, Exqlite.Error] ->
      # Database connectivity issues
      Logger.error(
        "DATABASE ERROR loading neglect thresholds, using defaults. This may indicate DB issues: #{inspect(e)}"
      )

      emit_settings_error_telemetry(:neglect_thresholds, e)
      @default_neglect_thresholds

    e ->
      # Unexpected error
      Logger.error(
        "Unexpected error loading neglect thresholds, using defaults: #{Exception.format(:error, e)}"
      )

      emit_settings_error_telemetry(:neglect_thresholds, e)
      @default_neglect_thresholds
  end

  defp emit_settings_error_telemetry(setting_type, exception) do
    :telemetry.execute(
      [:custyard, :scoring, :settings_error],
      %{count: 1},
      %{
        setting: setting_type,
        error_type: exception.__struct__,
        message: Exception.message(exception)
      }
    )
  end

  defp ensure_preloaded(struct, assoc) do
    if Ecto.assoc_loaded?(Map.get(struct, assoc)) do
      struct
    else
      Repo.preload(struct, assoc)
    end
  end
end
