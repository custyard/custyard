defmodule Custyard.Conversations.DormancyChecker do
  @moduledoc """
  Transitions stale waiting conversations to dormant state.

  A conversation becomes dormant when it has been in :waiting state with no
  customer action beyond the tier-based dormancy threshold. This prevents
  abandoned conversations from cluttering the attention queue.

  Dormancy thresholds match the neglect critical thresholds from Scoring:
  - Enterprise: 8 hours
  - Standard: 48 hours
  - Basic: 72 hours
  """

  import Ecto.Query
  alias Custyard.{Conversation, Repo}

  # Dormancy thresholds in hours (same as neglect critical thresholds)
  @dormancy_thresholds %{
    enterprise: 8,
    standard: 48,
    basic: 72
  }

  @doc """
  Find and transition all stale waiting conversations to dormant.

  Returns the count of transitioned conversations.
  """
  def transition_stale_conversations do
    stale_conversations()
    |> Enum.map(&transition_to_dormant/1)
    |> Enum.count(& &1)
  end

  @doc """
  Query conversations in :waiting state that have exceeded their dormancy threshold.
  """
  def stale_conversations do
    now = DateTime.utc_now()

    from(c in Conversation,
      join: o in assoc(c, :organization),
      where: c.state == :waiting,
      select: {c, o.tier}
    )
    |> Repo.all()
    |> Enum.filter(fn {conversation, tier} ->
      exceeds_dormancy_threshold?(conversation, tier, now)
    end)
    |> Enum.map(fn {conversation, _tier} -> conversation end)
  end

  defp exceeds_dormancy_threshold?(conversation, tier, now) do
    threshold_hours = Map.get(@dormancy_thresholds, tier, 48)
    reference_time = conversation.last_customer_action_at || conversation.inserted_at
    hours_idle = DateTime.diff(now, reference_time, :hour)

    hours_idle >= threshold_hours
  end

  defp transition_to_dormant(conversation) do
    case conversation
         |> Conversation.state_changeset(:dormant)
         |> Repo.update() do
      {:ok, updated} ->
        Phoenix.PubSub.broadcast(
          Custyard.PubSub,
          "conversations",
          {:conversation_updated, updated.id}
        )

        true

      {:error, _changeset} ->
        false
    end
  end
end
