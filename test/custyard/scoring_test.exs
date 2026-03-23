defmodule Custyard.ScoringTest do
  use Custyard.DataCase, async: true

  # TODO: Uncomment when Scoring module exists
  # alias Custyard.Scoring

  import Custyard.Factory

  describe "attention score formula" do
    # Score = log(idle_minutes + 1) * state_weight * tier_multiplier + urgency_bonus

    @tag :pending
    test "base score uses log scale for idle time" do
      # Logarithmic scaling prevents runaway scores for very old conversations
      # while still giving meaningful differentiation
      #
      # Expected behavior:
      # - 0 minutes idle -> log(1) = 0 base
      # - 10 minutes idle -> log(11) ~= 2.4 base
      # - 60 minutes idle -> log(61) ~= 4.1 base
      # - 1440 minutes (1 day) -> log(1441) ~= 7.3 base

      _conversation = build_conversation(
        state: :waiting,
        last_customer_action_at: DateTime.add(DateTime.utc_now(), -60, :minute)
      )

      # assert Scoring.calculate_idle_component(conversation) > 0
      # assert Scoring.calculate_idle_component(conversation) < 10
    end

    @tag :pending
    test "state weights reflect attention priority" do
      # State weights (expected):
      # - :new -> 1.5 (new conversations need triage)
      # - :active -> 1.0 (baseline, currently being handled)
      # - :waiting -> 2.0 (customer waiting, highest priority)
      # - :dormant -> 0.3 (low priority, may need nudge)
      # - :resolved -> 0.1 (minimal attention, just monitoring)

      # assert Scoring.state_weight(:new) == 1.5
      # assert Scoring.state_weight(:active) == 1.0
      # assert Scoring.state_weight(:waiting) == 2.0
      # assert Scoring.state_weight(:dormant) == 0.3
      # assert Scoring.state_weight(:resolved) == 0.1
    end

    @tag :pending
    test "tier multipliers favor paying customers" do
      # Tier multipliers (expected):
      # - :enterprise -> 3.0
      # - :standard -> 1.5
      # - :basic -> 1.0

      _org_enterprise = build_organization(tier: :enterprise)
      _org_standard = build_organization(tier: :standard)
      _org_basic = build_organization(tier: :basic)

      # assert Scoring.tier_multiplier(:enterprise) == 3.0
      # assert Scoring.tier_multiplier(:standard) == 1.5
      # assert Scoring.tier_multiplier(:basic) == 1.0
    end

    @tag :pending
    test "urgency bonus adds flat score increase" do
      # Urgency bonuses (expected):
      # - :urgent -> 30
      # - :elevated -> 15
      # - :normal -> 0

      # assert Scoring.urgency_bonus(:urgent) == 30
      # assert Scoring.urgency_bonus(:elevated) == 15
      # assert Scoring.urgency_bonus(:normal) == 0
    end
  end

  describe "neglect thresholds" do
    @tag :pending
    test "conversations become neglected after threshold" do
      # Neglect thresholds by state (expected idle time before flagging):
      # - :waiting -> 30 minutes
      # - :new -> 15 minutes
      # - :active -> 60 minutes
      # - :dormant -> 7 days
      # - :resolved -> never

      _waiting_conv = build_conversation(
        state: :waiting,
        last_customer_action_at: DateTime.add(DateTime.utc_now(), -35, :minute)
      )

      _new_conv = build_conversation(
        state: :new,
        last_customer_action_at: DateTime.add(DateTime.utc_now(), -20, :minute)
      )

      # assert Scoring.neglected?(waiting_conv)
      # assert Scoring.neglected?(new_conv)
    end

    @tag :pending
    test "recently active conversations are not neglected" do
      _conversation = build_conversation(
        state: :waiting,
        last_customer_action_at: DateTime.add(DateTime.utc_now(), -5, :minute)
      )

      # refute Scoring.neglected?(conversation)
    end

    @tag :pending
    test "resolved conversations are never neglected" do
      _conversation = build_conversation(
        state: :resolved,
        last_customer_action_at: DateTime.add(DateTime.utc_now(), -10080, :minute)  # 7 days
      )

      # refute Scoring.neglected?(conversation)
    end
  end

  describe "full score calculation" do
    @tag :pending
    test "enterprise customer waiting for 1 hour scores higher than basic new" do
      _enterprise_waiting = build_conversation(
        state: :waiting,
        urgency: :normal,
        last_customer_action_at: DateTime.add(DateTime.utc_now(), -60, :minute)
      )
      # Assume org tier: :enterprise

      _basic_new = build_conversation(
        state: :new,
        urgency: :normal,
        last_customer_action_at: DateTime.utc_now()
      )
      # Assume org tier: :basic

      # enterprise_score = Scoring.calculate(enterprise_waiting, tier: :enterprise)
      # basic_score = Scoring.calculate(basic_new, tier: :basic)
      # assert enterprise_score > basic_score
    end

    @tag :pending
    test "urgent priority elevates any conversation" do
      _urgent_dormant = build_conversation(
        state: :dormant,
        urgency: :urgent,
        last_customer_action_at: DateTime.add(DateTime.utc_now(), -5, :minute)
      )

      _normal_waiting = build_conversation(
        state: :waiting,
        urgency: :normal,
        last_customer_action_at: DateTime.add(DateTime.utc_now(), -30, :minute)
      )

      # urgent_score = Scoring.calculate(urgent_dormant, tier: :basic)
      # normal_score = Scoring.calculate(normal_waiting, tier: :basic)
      # assert urgent_score > normal_score
    end
  end
end
