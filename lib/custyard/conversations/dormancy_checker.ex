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
    enterprise_cutoff = hours_ago(@dormancy_thresholds.enterprise)
    standard_cutoff = hours_ago(@dormancy_thresholds.standard)
    basic_cutoff = hours_ago(@dormancy_thresholds.basic)

    from(c in Conversation,
      join: o in assoc(c, :organization),
      where: c.state == :waiting,
      where:
        (o.tier == :enterprise and
           coalesce(c.last_customer_action_at, c.inserted_at) <= ^enterprise_cutoff) or
          (o.tier == :standard and
             coalesce(c.last_customer_action_at, c.inserted_at) <= ^standard_cutoff) or
          (o.tier == :basic and
             coalesce(c.last_customer_action_at, c.inserted_at) <= ^basic_cutoff),
      select: c
    )
    |> Repo.all()
  end

  defp hours_ago(hours) do
    DateTime.add(DateTime.utc_now(), -hours, :hour)
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

        Phoenix.PubSub.broadcast(
          Custyard.PubSub,
          "conversations:org:#{updated.organization_id}",
          {:conversation_updated, updated.id}
        )

        true

      {:error, _changeset} ->
        false
    end
  end
end
