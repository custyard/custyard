defmodule Custyard.ScoringTest do
  use Custyard.DataCase, async: true

  alias Custyard.Scoring

  import Custyard.Factory

  describe "idle_score (via breakdown)" do
    # idle_score = min(40, ln(hours + 1) * 10)

    test "zero hours idle gives zero idle score" do
      org = insert_organization(tier: :standard)

      conversation =
        insert_conversation(
          organization_id: org.id,
          last_operator_action_at: DateTime.utc_now()
        )

      breakdown = Scoring.breakdown(conversation)
      assert breakdown.idle == 0
    end

    test "uses log scale for idle time in hours" do
      org = insert_organization(tier: :standard)

      # ~7 hours idle -> ln(8) * 10 ~= 20.79
      conversation =
        insert_conversation(
          organization_id: org.id,
          last_operator_action_at: DateTime.add(DateTime.utc_now(), -7, :hour)
        )

      breakdown = Scoring.breakdown(conversation)
      # ln(8) * 10 = 20.79..., rounded to 21
      assert breakdown.idle == 21
    end

    test "idle score caps at 40" do
      org = insert_organization(tier: :standard)

      # 100 hours idle -> ln(101) * 10 ~= 46.1, but capped at 40
      conversation =
        insert_conversation(
          organization_id: org.id,
          last_operator_action_at: DateTime.add(DateTime.utc_now(), -100, :hour)
        )

      breakdown = Scoring.breakdown(conversation)
      assert breakdown.idle == 40
    end

    test "falls back to inserted_at when last_operator_action_at is nil" do
      org = insert_organization(tier: :standard)

      # Create conversation with no operator action (nil)
      # The conversation was just inserted, so idle time ~= 0
      conversation =
        insert_conversation(
          organization_id: org.id,
          last_operator_action_at: nil
        )

      breakdown = Scoring.breakdown(conversation)
      # Just inserted, so idle hours ~= 0, idle score ~= 0
      assert breakdown.idle == 0
    end
  end

  describe "state_score (via breakdown)" do
    # @state_scores %{new: 30, active: 15, waiting: 0, dormant: 25, resolved: 0}

    test "new state scores 30" do
      org = insert_organization(tier: :standard)

      conversation =
        insert_conversation(
          organization_id: org.id,
          state: :new,
          last_operator_action_at: DateTime.utc_now()
        )

      breakdown = Scoring.breakdown(conversation)
      assert breakdown.state == 30
    end

    test "active state scores 15" do
      org = insert_organization(tier: :standard)

      conversation =
        insert_conversation(
          organization_id: org.id,
          state: :active,
          last_operator_action_at: DateTime.utc_now()
        )

      breakdown = Scoring.breakdown(conversation)
      assert breakdown.state == 15
    end

    test "waiting state scores 0" do
      org = insert_organization(tier: :standard)

      conversation =
        insert_conversation(
          organization_id: org.id,
          state: :waiting,
          last_operator_action_at: DateTime.utc_now()
        )

      breakdown = Scoring.breakdown(conversation)
      assert breakdown.state == 0
    end

    test "dormant state scores 25" do
      org = insert_organization(tier: :standard)

      conversation =
        insert_conversation(
          organization_id: org.id,
          state: :dormant,
          last_operator_action_at: DateTime.utc_now()
        )

      breakdown = Scoring.breakdown(conversation)
      assert breakdown.state == 25
    end

    test "resolved state scores 0" do
      org = insert_organization(tier: :standard)

      conversation =
        insert_conversation(
          organization_id: org.id,
          state: :resolved,
          last_operator_action_at: DateTime.utc_now()
        )

      breakdown = Scoring.breakdown(conversation)
      assert breakdown.state == 0
    end
  end

  describe "tier_score (via breakdown)" do
    # @tier_scores %{enterprise: 20, standard: 10, basic: 5}

    test "enterprise tier scores 20" do
      org = insert_organization(tier: :enterprise)

      conversation =
        insert_conversation(
          organization_id: org.id,
          state: :new,
          last_operator_action_at: DateTime.utc_now()
        )

      breakdown = Scoring.breakdown(conversation)
      assert breakdown.tier == 20
    end

    test "standard tier scores 10" do
      org = insert_organization(tier: :standard)

      conversation =
        insert_conversation(
          organization_id: org.id,
          state: :new,
          last_operator_action_at: DateTime.utc_now()
        )

      breakdown = Scoring.breakdown(conversation)
      assert breakdown.tier == 10
    end

    test "basic tier scores 5" do
      org = insert_organization(tier: :basic)

      conversation =
        insert_conversation(
          organization_id: org.id,
          state: :new,
          last_operator_action_at: DateTime.utc_now()
        )

      breakdown = Scoring.breakdown(conversation)
      assert breakdown.tier == 5
    end
  end

  describe "urgency_score (via breakdown)" do
    # @urgency_scores %{urgent: 15, elevated: 7, normal: 0}

    test "urgent urgency scores 15" do
      org = insert_organization(tier: :standard)

      conversation =
        insert_conversation(
          organization_id: org.id,
          urgency: :urgent,
          last_operator_action_at: DateTime.utc_now()
        )

      breakdown = Scoring.breakdown(conversation)
      assert breakdown.urgency == 15
    end

    test "elevated urgency scores 7" do
      org = insert_organization(tier: :standard)

      conversation =
        insert_conversation(
          organization_id: org.id,
          urgency: :elevated,
          last_operator_action_at: DateTime.utc_now()
        )

      breakdown = Scoring.breakdown(conversation)
      assert breakdown.urgency == 7
    end

    test "normal urgency scores 0" do
      org = insert_organization(tier: :standard)

      conversation =
        insert_conversation(
          organization_id: org.id,
          urgency: :normal,
          last_operator_action_at: DateTime.utc_now()
        )

      breakdown = Scoring.breakdown(conversation)
      assert breakdown.urgency == 0
    end
  end

  describe "velocity_score (via breakdown)" do
    # velocity_score = min(10, ln(message_count_24h + 1) * 3)

    test "no messages gives zero velocity score" do
      org = insert_organization(tier: :standard)

      conversation =
        insert_conversation(
          organization_id: org.id,
          last_operator_action_at: DateTime.utc_now()
        )

      breakdown = Scoring.breakdown(conversation)
      # ln(0 + 1) * 3 = 0
      assert breakdown.velocity == 0
    end

    test "messages in last 24h increase velocity score" do
      org = insert_organization(tier: :standard)

      conversation =
        insert_conversation(
          organization_id: org.id,
          last_operator_action_at: DateTime.utc_now()
        )

      # Insert 5 messages in last 24h
      for _ <- 1..5 do
        insert_message(conversation_id: conversation.id)
      end

      breakdown = Scoring.breakdown(conversation)
      # ln(5 + 1) * 3 = ln(6) * 3 ~= 5.38, rounded to 5
      assert breakdown.velocity == 5
    end

    test "velocity score caps at 10" do
      org = insert_organization(tier: :standard)

      conversation =
        insert_conversation(
          organization_id: org.id,
          last_operator_action_at: DateTime.utc_now()
        )

      # Insert 50 messages to exceed cap
      for _ <- 1..50 do
        insert_message(conversation_id: conversation.id)
      end

      breakdown = Scoring.breakdown(conversation)
      # ln(51) * 3 ~= 11.8, capped at 10
      assert breakdown.velocity == 10
    end
  end

  describe "neglect_status and neglect_bonus" do
    # @neglect_thresholds %{enterprise: {4, 8}, standard: {24, 48}, basic: {48, 72}}
    # neglect_bonus: critical=15, warning=7, ok=0

    test "enterprise critical after 8 hours idle" do
      org = insert_organization(tier: :enterprise)

      conversation =
        insert_conversation(
          organization_id: org.id,
          last_operator_action_at: DateTime.add(DateTime.utc_now(), -9, :hour)
        )

      assert Scoring.neglect_status(conversation) == :critical

      breakdown = Scoring.breakdown(conversation)
      assert breakdown.neglect_bonus == 15
    end

    test "enterprise warning after 4 hours idle" do
      org = insert_organization(tier: :enterprise)

      conversation =
        insert_conversation(
          organization_id: org.id,
          last_operator_action_at: DateTime.add(DateTime.utc_now(), -5, :hour)
        )

      assert Scoring.neglect_status(conversation) == :warning

      breakdown = Scoring.breakdown(conversation)
      assert breakdown.neglect_bonus == 7
    end

    test "enterprise ok within 4 hours" do
      org = insert_organization(tier: :enterprise)

      conversation =
        insert_conversation(
          organization_id: org.id,
          last_operator_action_at: DateTime.add(DateTime.utc_now(), -3, :hour)
        )

      assert Scoring.neglect_status(conversation) == :ok

      breakdown = Scoring.breakdown(conversation)
      assert breakdown.neglect_bonus == 0
    end

    test "standard critical after 48 hours idle" do
      org = insert_organization(tier: :standard)

      conversation =
        insert_conversation(
          organization_id: org.id,
          last_operator_action_at: DateTime.add(DateTime.utc_now(), -49, :hour)
        )

      assert Scoring.neglect_status(conversation) == :critical

      breakdown = Scoring.breakdown(conversation)
      assert breakdown.neglect_bonus == 15
    end

    test "standard warning after 24 hours idle" do
      org = insert_organization(tier: :standard)

      conversation =
        insert_conversation(
          organization_id: org.id,
          last_operator_action_at: DateTime.add(DateTime.utc_now(), -25, :hour)
        )

      assert Scoring.neglect_status(conversation) == :warning

      breakdown = Scoring.breakdown(conversation)
      assert breakdown.neglect_bonus == 7
    end

    test "basic critical after 72 hours idle" do
      org = insert_organization(tier: :basic)

      conversation =
        insert_conversation(
          organization_id: org.id,
          last_operator_action_at: DateTime.add(DateTime.utc_now(), -73, :hour)
        )

      assert Scoring.neglect_status(conversation) == :critical

      breakdown = Scoring.breakdown(conversation)
      assert breakdown.neglect_bonus == 15
    end

    test "basic warning after 48 hours idle" do
      org = insert_organization(tier: :basic)

      conversation =
        insert_conversation(
          organization_id: org.id,
          last_operator_action_at: DateTime.add(DateTime.utc_now(), -49, :hour)
        )

      assert Scoring.neglect_status(conversation) == :warning

      breakdown = Scoring.breakdown(conversation)
      assert breakdown.neglect_bonus == 7
    end
  end

  describe "calculate/1 - full score calculation" do
    test "calculates sum of all components with default weights" do
      org = insert_organization(tier: :enterprise)

      # Create conversation: new state, urgent, 7 hours idle
      conversation =
        insert_conversation(
          organization_id: org.id,
          state: :new,
          urgency: :urgent,
          last_operator_action_at: DateTime.add(DateTime.utc_now(), -7, :hour)
        )

      # Add 3 messages for velocity
      for _ <- 1..3 do
        insert_message(conversation_id: conversation.id)
      end

      breakdown = Scoring.breakdown(conversation)
      total = Scoring.calculate(conversation)

      # Verify breakdown components sum to total
      expected_total =
        breakdown.idle + breakdown.state + breakdown.tier + breakdown.urgency +
          breakdown.velocity + breakdown.neglect_bonus

      assert total == expected_total

      # With 7 hours idle on enterprise (warning threshold at 4h):
      # idle: ln(8) * 10 ~= 21
      # state: 30 (new)
      # tier: 20 (enterprise)
      # urgency: 15 (urgent)
      # velocity: ln(4) * 3 ~= 4
      # neglect: 7 (warning, 4-8h range)
      # Total: ~97
      assert breakdown.idle == 21
      assert breakdown.state == 30
      assert breakdown.tier == 20
      assert breakdown.urgency == 15
      assert breakdown.velocity == 4
      assert breakdown.neglect_bonus == 7
      assert total == 97
    end

    test "enterprise customer new conversation scores higher than basic" do
      enterprise_org = insert_organization(tier: :enterprise)
      basic_org = insert_organization(tier: :basic)

      enterprise_conversation =
        insert_conversation(
          organization_id: enterprise_org.id,
          state: :new,
          urgency: :normal,
          last_operator_action_at: DateTime.utc_now()
        )

      basic_conversation =
        insert_conversation(
          organization_id: basic_org.id,
          state: :new,
          urgency: :normal,
          last_operator_action_at: DateTime.utc_now()
        )

      enterprise_score = Scoring.calculate(enterprise_conversation)
      basic_score = Scoring.calculate(basic_conversation)

      # Enterprise: 0 + 30 + 20 + 0 + 0 + 0 = 50
      # Basic: 0 + 30 + 5 + 0 + 0 + 0 = 35
      assert enterprise_score == 50
      assert basic_score == 35
      assert enterprise_score > basic_score
    end

    test "urgent priority elevates score significantly" do
      org = insert_organization(tier: :basic)

      urgent_conversation =
        insert_conversation(
          organization_id: org.id,
          state: :dormant,
          urgency: :urgent,
          last_operator_action_at: DateTime.utc_now()
        )

      normal_conversation =
        insert_conversation(
          organization_id: org.id,
          state: :new,
          urgency: :normal,
          last_operator_action_at: DateTime.utc_now()
        )

      urgent_score = Scoring.calculate(urgent_conversation)
      normal_score = Scoring.calculate(normal_conversation)

      # Urgent dormant: 0 + 25 + 5 + 15 + 0 + 0 = 45
      # Normal new: 0 + 30 + 5 + 0 + 0 + 0 = 35
      assert urgent_score == 45
      assert normal_score == 35
      assert urgent_score > normal_score
    end
  end

  describe "calculate_and_cache/1" do
    test "updates cached_score on conversation" do
      org = insert_organization(tier: :standard)

      conversation =
        insert_conversation(
          organization_id: org.id,
          state: :new,
          urgency: :normal,
          last_operator_action_at: DateTime.utc_now()
        )

      assert conversation.cached_score == 0

      score = Scoring.calculate_and_cache(conversation.id)

      # Reload from DB
      updated = Custyard.Repo.get!(Custyard.Conversation, conversation.id)
      assert updated.cached_score == score
      # new(30) + standard(10) = 40
      assert score == 40
    end
  end
end
