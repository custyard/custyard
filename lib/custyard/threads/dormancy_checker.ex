defmodule Custyard.Threads.DormancyChecker do
  @moduledoc """
  Transitions stale waiting threads to dormant state.

  A thread becomes dormant when it has been in :waiting state with no
  customer action beyond the tier-based dormancy threshold. This is the
  automatic `waiting -> dormant` transition described in `docs/design/sdd.md`
  §74/§80 — an inactivity signal, not a suppression one. Dormant threads
  stay in the attention queue (`Threads.list_for_attention_queue/1`
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
  alias Custyard.{Thread, Threads, Repo, Settings}

  # Organization tiers carrying their own dormancy threshold. Unlinked
  # threads have no tier and are handled separately, on the standard
  # cutoff, matching `Scoring.neglect_tier/1` and `NeglectChecker`.
  @dormancy_tiers [:enterprise, :standard, :basic]

  @doc """
  Find and transition all stale waiting threads to dormant.

  Returns the count of transitioned threads.
  """
  def transition_stale_threads do
    Custyard.Tenants.list_tenants()
    |> Enum.filter(&(&1.status == "active"))
    |> Enum.map(fn tenant ->
      thresholds = Settings.get_neglect_thresholds(tenant.id)

      stale_query(thresholds, tenant.id)
      |> Repo.all()
      |> Enum.count(&transition_to_dormant(&1, thresholds))
    end)
    |> Enum.sum()
  end

  @doc """
  Query threads in :waiting state that have exceeded their dormancy threshold.

  Uses the critical threshold from Settings.get_neglect_thresholds/0 as the
  dormancy cutoff for each tier.

  Unlinked threads (nil organization — public intake and disambiguation)
  have no tier to join against, so they are matched by a dedicated
  `is_nil(organization_id)` branch on the standard-tier cutoff. That mirrors
  `Scoring.neglect_tier/1` and `NeglectChecker.list_notification_candidates/1`.
  The join is a LEFT join purely so those rows survive it — on its own it
  changes nothing, because every tier comparison is NULL for them and
  `NULL OR NULL OR NULL` is not TRUE.
  """
  def stale_threads(tenant_id) do
    # Thresholds are database-configurable; the critical threshold doubles as
    # the dormancy cutoff.
    Settings.get_neglect_thresholds(tenant_id)
    |> stale_query(tenant_id)
    |> Repo.all()
  end

  defp stale_query(thresholds, tenant_id) do
    from(c in Thread,
      left_join: o in assoc(c, :organization),
      where: c.tenant_id == ^tenant_id,
      where: c.state == :waiting,
      where: ^past_dormancy_cutoff(thresholds)
    )
  end

  # One OR branch per tier, plus the unlinked branch. Composed rather than
  # written out so the boolean stays readable and the tier list has a single
  # source of truth.
  defp past_dormancy_cutoff(thresholds) do
    unlinked_cutoff = dormancy_cutoff(thresholds, :standard)

    unlinked =
      dynamic(
        [c],
        is_nil(c.organization_id) and ^quiet_since(unlinked_cutoff)
      )

    Enum.reduce(@dormancy_tiers, unlinked, fn tier, acc ->
      cutoff = dormancy_cutoff(thresholds, tier)

      dynamic(
        [c, o],
        ^acc or (o.tier == ^tier and ^quiet_since(cutoff))
      )
    end)
  end

  # Dormant means no activity from either side for the whole period
  # (sdd.md, US-3). Measuring only the customer side turned a thread
  # dormant minutes after the staff replied and marked it waiting, before
  # the customer had any chance to answer. An staff who never acted does
  # not hold the thread back.
  defp quiet_since(cutoff) do
    dynamic(
      [c],
      coalesce(c.last_customer_action_at, c.inserted_at) <= ^cutoff and
        (is_nil(c.last_staff_action_at) or c.last_staff_action_at <= ^cutoff)
    )
  end

  defp dormancy_cutoff(thresholds, tier) do
    {_warning, critical} = Map.fetch!(thresholds, tier)
    hours_ago(critical)
  end

  defp hours_ago(hours) do
    DateTime.add(DateTime.utc_now(), -hours, :hour)
  end

  # Guarded by the whole stale condition, re-evaluated by the UPDATE itself:
  # a customer reply that reactivated the thread, or a staff reply
  # that left it :waiting, between the SELECT above and this UPDATE must win,
  # not be overwritten with :dormant from a stale struct.
  defp transition_to_dormant(%Thread{id: id} = thread, thresholds) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    still_stale =
      from(c in stale_query(thresholds, thread.tenant_id), where: c.id == ^id, select: c.id)

    {count, _} =
      from(c in Thread, where: c.id in subquery(still_stale))
      |> Repo.update_all(set: [state: :dormant, updated_at: now])

    if count == 1 do
      Phoenix.PubSub.broadcast(
        Custyard.PubSub,
        "threads",
        {:thread_updated, id}
      )

      Threads.broadcast_to_org(
        thread.organization_id,
        {:thread_updated, id}
      )

      true
    else
      false
    end
  end
end
