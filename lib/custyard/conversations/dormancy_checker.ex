defmodule Custyard.Conversations.DormancyChecker do
  @moduledoc """
  Transitions stale waiting conversations to dormant state.

  A conversation becomes dormant when it has been in :waiting state with no
  customer action beyond the tier-based dormancy threshold. This is the
  automatic `waiting -> dormant` transition described in `docs/design/sdd.md`
  §74/§80 — an inactivity signal, not a suppression one. Dormant conversations
  stay in the attention queue (`Conversations.list_for_attention_queue/1`
  excludes only `:resolved` and snoozed rows) and score *higher* than waiting
  ones (`Scoring` weights dormant 25 against waiting 0), so the transition
  raises queue position rather than lowering it. `sdd.md` §477 describes a
  queue filtered to actionable states that the implementation does not have;
  that divergence is tracked separately.

  Dormancy thresholds use the neglect critical thresholds from Settings:
  - Enterprise: default 8 hours
  - Standard: default 48 hours
  - Basic: default 72 hours

  These thresholds are database-configurable via the Settings module.
  """

  import Ecto.Query
  alias Custyard.{Conversation, Conversations, Repo, Settings}

  # Organization tiers carrying their own dormancy threshold. Unlinked
  # conversations have no tier and are handled separately, on the standard
  # cutoff, matching `Scoring.neglect_tier/1` and `NeglectChecker`.
  @dormancy_tiers [:enterprise, :standard, :basic]

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

  Uses the critical threshold from Settings.get_neglect_thresholds/0 as the
  dormancy cutoff for each tier.

  Unlinked conversations (nil organization — public intake and disambiguation)
  have no tier to join against, so they are matched by a dedicated
  `is_nil(organization_id)` branch on the standard-tier cutoff. That mirrors
  `Scoring.neglect_tier/1` and `NeglectChecker.list_notification_candidates/1`.
  The join is a LEFT join purely so those rows survive it — on its own it
  changes nothing, because every tier comparison is NULL for them and
  `NULL OR NULL OR NULL` is not TRUE.
  """
  def stale_conversations do
    # Thresholds are database-configurable; the critical threshold doubles as
    # the dormancy cutoff.
    thresholds = Settings.get_neglect_thresholds()

    from(c in Conversation,
      left_join: o in assoc(c, :organization),
      where: c.state == :waiting,
      where: ^past_dormancy_cutoff(thresholds),
      select: c
    )
    |> Repo.all()
  end

  # One OR branch per tier, plus the unlinked branch. Composed rather than
  # written out so the boolean stays readable and the tier list has a single
  # source of truth.
  defp past_dormancy_cutoff(thresholds) do
    unlinked_cutoff = dormancy_cutoff(thresholds, :standard)

    unlinked =
      dynamic(
        [c],
        is_nil(c.organization_id) and
          coalesce(c.last_customer_action_at, c.inserted_at) <= ^unlinked_cutoff
      )

    Enum.reduce(@dormancy_tiers, unlinked, fn tier, acc ->
      cutoff = dormancy_cutoff(thresholds, tier)

      dynamic(
        [c, o],
        ^acc or
          (o.tier == ^tier and
             coalesce(c.last_customer_action_at, c.inserted_at) <= ^cutoff)
      )
    end)
  end

  defp dormancy_cutoff(thresholds, tier) do
    {_warning, critical} = Map.fetch!(thresholds, tier)
    hours_ago(critical)
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

        Conversations.broadcast_to_org(
          updated.organization_id,
          {:conversation_updated, updated.id}
        )

        true

      {:error, _changeset} ->
        false
    end
  end
end
