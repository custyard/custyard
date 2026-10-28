defmodule Custyard.Scoring.SchedulerTest do
  @moduledoc """
  Tests for the Scoring.Scheduler GenServer and related batch operations.

  These tests focus on the Recalculator, DormancyChecker and InboundChannels
  quiet-check functions that the Scheduler orchestrates, avoiding conflicts
  with the application-started Scheduler process.
  """
  use Custyard.DataCase, async: true

  alias Custyard.{Thread, InboundChannels, Repo, Scoring}
  alias Custyard.Threads.DormancyChecker
  alias Custyard.Scoring.Recalculator

  import Custyard.Factory

  describe "Recalculator.recalculate_all/0" do
    test "recalculates scores for new threads" do
      org = insert_organization(tier: :enterprise)

      thread =
        insert_thread(
          organization_id: org.id,
          state: :new,
          cached_score: 0,
          last_staff_action_at: DateTime.utc_now()
        )

      assert thread.cached_score == 0

      Recalculator.recalculate_all()

      updated = Repo.get!(Thread, thread.id)
      # new(30) + enterprise(20) = 50
      assert updated.cached_score == 50
    end

    test "recalculates scores for active threads" do
      org = insert_organization(tier: :standard)

      thread =
        insert_thread(
          organization_id: org.id,
          state: :active,
          cached_score: 0,
          last_staff_action_at: DateTime.utc_now()
        )

      Recalculator.recalculate_all()

      updated = Repo.get!(Thread, thread.id)
      # active(15) + standard(10) = 25
      assert updated.cached_score == 25
    end

    test "recalculates scores for waiting threads" do
      org = insert_organization(tier: :basic)

      thread =
        insert_thread(
          organization_id: org.id,
          state: :waiting,
          cached_score: 0,
          last_staff_action_at: DateTime.utc_now()
        )

      Recalculator.recalculate_all()

      updated = Repo.get!(Thread, thread.id)
      # waiting(0) + basic(5) = 5
      assert updated.cached_score == 5
    end

    test "recalculates scores for dormant threads" do
      org = insert_organization(tier: :standard)

      thread =
        insert_thread(
          organization_id: org.id,
          state: :dormant,
          cached_score: 0,
          last_staff_action_at: DateTime.utc_now()
        )

      Recalculator.recalculate_all()

      updated = Repo.get!(Thread, thread.id)
      # dormant(25) + standard(10) = 35
      assert updated.cached_score == 35
    end

    test "skips resolved threads" do
      org = insert_organization(tier: :standard)

      thread =
        insert_thread(
          organization_id: org.id,
          state: :resolved,
          cached_score: 0,
          last_staff_action_at: DateTime.utc_now()
        )

      Recalculator.recalculate_all()

      updated = Repo.get!(Thread, thread.id)
      # Resolved should not be updated
      assert updated.cached_score == 0
    end

    test "skips currently snoozed threads" do
      org = insert_organization(tier: :standard)

      thread =
        insert_thread(
          organization_id: org.id,
          state: :new,
          cached_score: 0,
          snoozed_until: DateTime.add(DateTime.utc_now(), 1, :hour),
          last_staff_action_at: DateTime.utc_now()
        )

      Recalculator.recalculate_all()

      updated = Repo.get!(Thread, thread.id)
      # Snoozed should not be updated
      assert updated.cached_score == 0
    end

    test "recalculates threads with expired snooze" do
      org = insert_organization(tier: :standard)

      thread =
        insert_thread(
          organization_id: org.id,
          state: :new,
          cached_score: 0,
          snoozed_until: DateTime.add(DateTime.utc_now(), -1, :hour),
          last_staff_action_at: DateTime.utc_now()
        )

      Recalculator.recalculate_all()

      updated = Repo.get!(Thread, thread.id)
      # Expired snooze should be recalculated
      # new(30) + standard(10) = 40
      assert updated.cached_score == 40
    end

    test "recalculates multiple threads" do
      org = insert_organization(tier: :standard)

      threads =
        for _ <- 1..5 do
          insert_thread(
            organization_id: org.id,
            state: :new,
            cached_score: 0,
            last_staff_action_at: DateTime.utc_now()
          )
        end

      Recalculator.recalculate_all()

      for conv <- threads do
        updated = Repo.get!(Thread, conv.id)
        assert updated.cached_score == 40
      end
    end

    test "updates idle score component correctly" do
      org = insert_organization(tier: :standard)

      # 10 hours idle - should have significant idle score
      thread =
        insert_thread(
          organization_id: org.id,
          state: :new,
          cached_score: 0,
          last_staff_action_at: DateTime.add(DateTime.utc_now(), -10, :hour)
        )

      Recalculator.recalculate_all()

      updated = Repo.get!(Thread, thread.id)
      breakdown = Scoring.breakdown(updated)

      # idle: ln(11) * 10 ~= 24
      # new(30) + standard(10) + idle(24) = 64
      assert breakdown.idle == 24
      assert updated.cached_score == 64
    end
  end

  describe "DormancyChecker.transition_stale_threads/0" do
    test "transitions waiting thread past threshold to dormant" do
      org = insert_organization(tier: :standard)

      # 50 hours idle on both sides - past standard dormancy threshold (48h)
      idle_since = DateTime.add(DateTime.utc_now(), -50, :hour)

      thread =
        insert_thread(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: idle_since,
          last_staff_action_at: idle_since
        )

      count = DormancyChecker.transition_stale_threads()

      assert count == 1

      updated = Repo.get!(Thread, thread.id)
      assert updated.state == :dormant
    end

    test "does not transition recent waiting threads" do
      org = insert_organization(tier: :standard)

      # 1 hour idle - well within threshold
      thread =
        insert_thread(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: DateTime.add(DateTime.utc_now(), -1, :hour),
          last_staff_action_at: DateTime.utc_now()
        )

      count = DormancyChecker.transition_stale_threads()

      assert count == 0

      updated = Repo.get!(Thread, thread.id)
      assert updated.state == :waiting
    end

    test "respects enterprise tier threshold (8 hours)" do
      org = insert_organization(tier: :enterprise)

      # 10 hours idle on both sides - past enterprise threshold (8h)
      idle_since = DateTime.add(DateTime.utc_now(), -10, :hour)

      thread =
        insert_thread(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: idle_since,
          last_staff_action_at: idle_since
        )

      count = DormancyChecker.transition_stale_threads()

      assert count == 1

      updated = Repo.get!(Thread, thread.id)
      assert updated.state == :dormant
    end

    test "respects basic tier threshold (72 hours)" do
      org = insert_organization(tier: :basic)

      # 50 hours idle on both sides - under basic threshold (72h)
      idle_since = DateTime.add(DateTime.utc_now(), -50, :hour)

      thread =
        insert_thread(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: idle_since,
          last_staff_action_at: idle_since
        )

      count = DormancyChecker.transition_stale_threads()

      assert count == 0

      updated = Repo.get!(Thread, thread.id)
      assert updated.state == :waiting

      # Now test past threshold
      idle_since = DateTime.utc_now() |> DateTime.add(-75, :hour) |> DateTime.truncate(:second)

      Repo.update!(
        Ecto.Changeset.change(updated,
          last_customer_action_at: idle_since,
          last_staff_action_at: idle_since
        )
      )

      count = DormancyChecker.transition_stale_threads()
      assert count == 1

      final = Repo.get!(Thread, thread.id)
      assert final.state == :dormant
    end

    test "only transitions waiting state threads" do
      org = insert_organization(tier: :standard)

      # Create threads in various states, all past threshold
      new_conv =
        insert_thread(
          organization_id: org.id,
          state: :new,
          last_customer_action_at: DateTime.add(DateTime.utc_now(), -100, :hour)
        )

      active_conv =
        insert_thread(
          organization_id: org.id,
          state: :active,
          last_customer_action_at: DateTime.add(DateTime.utc_now(), -100, :hour)
        )

      waiting_conv =
        insert_thread(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: DateTime.add(DateTime.utc_now(), -100, :hour)
        )

      count = DormancyChecker.transition_stale_threads()

      # Only waiting should transition
      assert count == 1

      assert Repo.get!(Thread, new_conv.id).state == :new
      assert Repo.get!(Thread, active_conv.id).state == :active
      assert Repo.get!(Thread, waiting_conv.id).state == :dormant
    end

    test "transitions multiple stale threads" do
      org = insert_organization(tier: :standard)

      threads =
        for _ <- 1..3 do
          insert_thread(
            organization_id: org.id,
            state: :waiting,
            last_customer_action_at: DateTime.add(DateTime.utc_now(), -100, :hour)
          )
        end

      count = DormancyChecker.transition_stale_threads()

      assert count == 3

      for conv <- threads do
        updated = Repo.get!(Thread, conv.id)
        assert updated.state == :dormant
      end
    end
  end

  describe "InboundChannels.check_quiet_channels/1" do
    test "returns the number of channels notified in the scheduler's result shape" do
      assert {:ok, 0} = InboundChannels.check_quiet_channels()

      quiet_since =
        DateTime.utc_now() |> DateTime.add(-100, :hour) |> DateTime.truncate(:second)

      insert_inbound_channel(state: :active, last_received_at: quiet_since)

      assert {:ok, 1} = InboundChannels.check_quiet_channels()
      assert {:ok, 0} = InboundChannels.check_quiet_channels()
    end
  end

  describe "batch score refresh integration" do
    test "scores increase with idle time on repeated recalculations" do
      org = insert_organization(tier: :standard)

      thread =
        insert_thread(
          organization_id: org.id,
          state: :new,
          cached_score: 0,
          last_staff_action_at: DateTime.utc_now()
        )

      # First recalculation - no idle time
      Recalculator.recalculate_all()
      score1 = Repo.get!(Thread, thread.id).cached_score

      # Simulate time passing
      conv = Repo.get!(Thread, thread.id)

      Repo.update!(
        Ecto.Changeset.change(conv,
          last_staff_action_at:
            DateTime.utc_now() |> DateTime.add(-5, :hour) |> DateTime.truncate(:second)
        )
      )

      # Second recalculation - with idle time
      Recalculator.recalculate_all()
      score2 = Repo.get!(Thread, thread.id).cached_score

      # Score should be higher due to idle time
      assert score2 > score1
    end
  end
end
