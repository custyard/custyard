defmodule Custyard.Scoring.SchedulerTest do
  @moduledoc """
  Tests for the Scoring.Scheduler GenServer and related batch operations.

  These tests focus on the Recalculator and DormancyChecker modules that
  the Scheduler orchestrates, avoiding conflicts with the application-started
  Scheduler process.
  """
  use Custyard.DataCase, async: true

  alias Custyard.{Conversation, Repo, Scoring}
  alias Custyard.Conversations.DormancyChecker
  alias Custyard.Scoring.Recalculator

  import Custyard.Factory

  describe "Recalculator.recalculate_all/0" do
    test "recalculates scores for new conversations" do
      org = insert_organization(tier: :enterprise)

      conversation =
        insert_conversation(
          organization_id: org.id,
          state: :new,
          cached_score: 0,
          last_operator_action_at: DateTime.utc_now()
        )

      assert conversation.cached_score == 0

      Recalculator.recalculate_all()

      updated = Repo.get!(Conversation, conversation.id)
      # new(30) + enterprise(20) = 50
      assert updated.cached_score == 50
    end

    test "recalculates scores for active conversations" do
      org = insert_organization(tier: :standard)

      conversation =
        insert_conversation(
          organization_id: org.id,
          state: :active,
          cached_score: 0,
          last_operator_action_at: DateTime.utc_now()
        )

      Recalculator.recalculate_all()

      updated = Repo.get!(Conversation, conversation.id)
      # active(15) + standard(10) = 25
      assert updated.cached_score == 25
    end

    test "recalculates scores for waiting conversations" do
      org = insert_organization(tier: :basic)

      conversation =
        insert_conversation(
          organization_id: org.id,
          state: :waiting,
          cached_score: 0,
          last_operator_action_at: DateTime.utc_now()
        )

      Recalculator.recalculate_all()

      updated = Repo.get!(Conversation, conversation.id)
      # waiting(0) + basic(5) = 5
      assert updated.cached_score == 5
    end

    test "recalculates scores for dormant conversations" do
      org = insert_organization(tier: :standard)

      conversation =
        insert_conversation(
          organization_id: org.id,
          state: :dormant,
          cached_score: 0,
          last_operator_action_at: DateTime.utc_now()
        )

      Recalculator.recalculate_all()

      updated = Repo.get!(Conversation, conversation.id)
      # dormant(25) + standard(10) = 35
      assert updated.cached_score == 35
    end

    test "skips resolved conversations" do
      org = insert_organization(tier: :standard)

      conversation =
        insert_conversation(
          organization_id: org.id,
          state: :resolved,
          cached_score: 0,
          last_operator_action_at: DateTime.utc_now()
        )

      Recalculator.recalculate_all()

      updated = Repo.get!(Conversation, conversation.id)
      # Resolved should not be updated
      assert updated.cached_score == 0
    end

    test "skips currently snoozed conversations" do
      org = insert_organization(tier: :standard)

      conversation =
        insert_conversation(
          organization_id: org.id,
          state: :new,
          cached_score: 0,
          snoozed_until: DateTime.add(DateTime.utc_now(), 1, :hour),
          last_operator_action_at: DateTime.utc_now()
        )

      Recalculator.recalculate_all()

      updated = Repo.get!(Conversation, conversation.id)
      # Snoozed should not be updated
      assert updated.cached_score == 0
    end

    test "recalculates conversations with expired snooze" do
      org = insert_organization(tier: :standard)

      conversation =
        insert_conversation(
          organization_id: org.id,
          state: :new,
          cached_score: 0,
          snoozed_until: DateTime.add(DateTime.utc_now(), -1, :hour),
          last_operator_action_at: DateTime.utc_now()
        )

      Recalculator.recalculate_all()

      updated = Repo.get!(Conversation, conversation.id)
      # Expired snooze should be recalculated
      # new(30) + standard(10) = 40
      assert updated.cached_score == 40
    end

    test "recalculates multiple conversations" do
      org = insert_organization(tier: :standard)

      conversations =
        for _ <- 1..5 do
          insert_conversation(
            organization_id: org.id,
            state: :new,
            cached_score: 0,
            last_operator_action_at: DateTime.utc_now()
          )
        end

      Recalculator.recalculate_all()

      for conv <- conversations do
        updated = Repo.get!(Conversation, conv.id)
        assert updated.cached_score == 40
      end
    end

    test "updates idle score component correctly" do
      org = insert_organization(tier: :standard)

      # 10 hours idle - should have significant idle score
      conversation =
        insert_conversation(
          organization_id: org.id,
          state: :new,
          cached_score: 0,
          last_operator_action_at: DateTime.add(DateTime.utc_now(), -10, :hour)
        )

      Recalculator.recalculate_all()

      updated = Repo.get!(Conversation, conversation.id)
      breakdown = Scoring.breakdown(updated)

      # idle: ln(11) * 10 ~= 24
      # new(30) + standard(10) + idle(24) = 64
      assert breakdown.idle == 24
      assert updated.cached_score == 64
    end
  end

  describe "DormancyChecker.transition_stale_conversations/0" do
    test "transitions waiting conversation past threshold to dormant" do
      org = insert_organization(tier: :standard)

      # 50 hours idle - past standard dormancy threshold (48h)
      conversation =
        insert_conversation(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: DateTime.add(DateTime.utc_now(), -50, :hour),
          last_operator_action_at: DateTime.utc_now()
        )

      count = DormancyChecker.transition_stale_conversations()

      assert count == 1

      updated = Repo.get!(Conversation, conversation.id)
      assert updated.state == :dormant
    end

    test "does not transition recent waiting conversations" do
      org = insert_organization(tier: :standard)

      # 1 hour idle - well within threshold
      conversation =
        insert_conversation(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: DateTime.add(DateTime.utc_now(), -1, :hour),
          last_operator_action_at: DateTime.utc_now()
        )

      count = DormancyChecker.transition_stale_conversations()

      assert count == 0

      updated = Repo.get!(Conversation, conversation.id)
      assert updated.state == :waiting
    end

    test "respects enterprise tier threshold (8 hours)" do
      org = insert_organization(tier: :enterprise)

      # 10 hours idle - past enterprise threshold (8h)
      conversation =
        insert_conversation(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: DateTime.add(DateTime.utc_now(), -10, :hour),
          last_operator_action_at: DateTime.utc_now()
        )

      count = DormancyChecker.transition_stale_conversations()

      assert count == 1

      updated = Repo.get!(Conversation, conversation.id)
      assert updated.state == :dormant
    end

    test "respects basic tier threshold (72 hours)" do
      org = insert_organization(tier: :basic)

      # 50 hours idle - under basic threshold (72h)
      conversation =
        insert_conversation(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: DateTime.add(DateTime.utc_now(), -50, :hour),
          last_operator_action_at: DateTime.utc_now()
        )

      count = DormancyChecker.transition_stale_conversations()

      assert count == 0

      updated = Repo.get!(Conversation, conversation.id)
      assert updated.state == :waiting

      # Now test past threshold
      Repo.update!(
        Ecto.Changeset.change(updated,
          last_customer_action_at:
            DateTime.utc_now() |> DateTime.add(-75, :hour) |> DateTime.truncate(:second)
        )
      )

      count = DormancyChecker.transition_stale_conversations()
      assert count == 1

      final = Repo.get!(Conversation, conversation.id)
      assert final.state == :dormant
    end

    test "only transitions waiting state conversations" do
      org = insert_organization(tier: :standard)

      # Create conversations in various states, all past threshold
      new_conv =
        insert_conversation(
          organization_id: org.id,
          state: :new,
          last_customer_action_at: DateTime.add(DateTime.utc_now(), -100, :hour)
        )

      active_conv =
        insert_conversation(
          organization_id: org.id,
          state: :active,
          last_customer_action_at: DateTime.add(DateTime.utc_now(), -100, :hour)
        )

      waiting_conv =
        insert_conversation(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: DateTime.add(DateTime.utc_now(), -100, :hour)
        )

      count = DormancyChecker.transition_stale_conversations()

      # Only waiting should transition
      assert count == 1

      assert Repo.get!(Conversation, new_conv.id).state == :new
      assert Repo.get!(Conversation, active_conv.id).state == :active
      assert Repo.get!(Conversation, waiting_conv.id).state == :dormant
    end

    test "transitions multiple stale conversations" do
      org = insert_organization(tier: :standard)

      conversations =
        for _ <- 1..3 do
          insert_conversation(
            organization_id: org.id,
            state: :waiting,
            last_customer_action_at: DateTime.add(DateTime.utc_now(), -100, :hour)
          )
        end

      count = DormancyChecker.transition_stale_conversations()

      assert count == 3

      for conv <- conversations do
        updated = Repo.get!(Conversation, conv.id)
        assert updated.state == :dormant
      end
    end
  end

  describe "batch score refresh integration" do
    test "scores increase with idle time on repeated recalculations" do
      org = insert_organization(tier: :standard)

      conversation =
        insert_conversation(
          organization_id: org.id,
          state: :new,
          cached_score: 0,
          last_operator_action_at: DateTime.utc_now()
        )

      # First recalculation - no idle time
      Recalculator.recalculate_all()
      score1 = Repo.get!(Conversation, conversation.id).cached_score

      # Simulate time passing
      conv = Repo.get!(Conversation, conversation.id)

      Repo.update!(
        Ecto.Changeset.change(conv,
          last_operator_action_at:
            DateTime.utc_now() |> DateTime.add(-5, :hour) |> DateTime.truncate(:second)
        )
      )

      # Second recalculation - with idle time
      Recalculator.recalculate_all()
      score2 = Repo.get!(Conversation, conversation.id).cached_score

      # Score should be higher due to idle time
      assert score2 > score1
    end
  end
end
