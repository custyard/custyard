defmodule Custyard.Scoring do
  @moduledoc """
  Attention score calculation for the queue ranking algorithm.

  Score = (idle_weight * idle_score) + (state_weight * state_score) +
          (tier_weight * tier_score) + (urgency_weight * urgency_score) +
          (velocity_weight * velocity_score) + neglect_bonus
  """

  import Ecto.Query
  alias Custyard.{Repo, Conversation, Message, Settings}

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

  @doc "Calculate and cache score for a conversation"
  def calculate_and_cache(conversation_id) do
    conversation = Repo.get!(Conversation, conversation_id) |> Repo.preload(:organization)
    score = calculate(conversation)

    conversation
    |> Ecto.Changeset.change(cached_score: score)
    |> Repo.update!()

    score
  end

  @doc "Calculate score without caching (for display/debugging)"
  def calculate(conversation) do
    conversation = Repo.preload(conversation, :organization)
    weights = get_weights()

    idle = idle_score(conversation) * weights.idle
    state = state_score(conversation) * weights.state
    tier = tier_score(conversation) * weights.tier
    urgency = urgency_score(conversation) * weights.urgency
    velocity = velocity_score(conversation) * weights.velocity
    neglect = neglect_bonus(conversation) * weights.neglect

    round(idle + state + tier + urgency + velocity + neglect)
  end

  @doc "Get score breakdown for transparency UI"
  def breakdown(conversation) do
    conversation = Repo.preload(conversation, :organization)

    %{
      idle: round(idle_score(conversation)),
      state: round(state_score(conversation)),
      tier: round(tier_score(conversation)),
      urgency: round(urgency_score(conversation)),
      velocity: round(velocity_score(conversation)),
      neglect_bonus: round(neglect_bonus(conversation)),
      total: calculate(conversation)
    }
  end

  @doc "Get neglect status for a conversation"
  def neglect_status(conversation) do
    conversation = Repo.preload(conversation, :organization)
    hours_idle = hours_since_operator_action(conversation)
    tier = conversation.organization.tier
    thresholds = get_neglect_thresholds()
    {warning, critical} = Map.get(thresholds, tier, {24, 48})

    cond do
      hours_idle >= critical -> :critical
      hours_idle >= warning -> :warning
      true -> :ok
    end
  end

  # Private functions

  defp idle_score(conversation) do
    hours = hours_since_operator_action(conversation)
    # Log scale: ln(hours + 1) * 10, capped at 40
    min(40, :math.log(hours + 1) * 10)
  end

  defp state_score(conversation) do
    Map.get(@state_scores, conversation.state, 0)
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

  defp get_weights do
    try do
      Settings.get_weights()
    rescue
      _ -> %{idle: 1.0, state: 1.0, tier: 1.0, urgency: 1.0, velocity: 1.0, neglect: 1.0}
    end
  end

  defp get_neglect_thresholds do
    try do
      Settings.get_neglect_thresholds()
    rescue
      _ -> @default_neglect_thresholds
    end
  end
end
