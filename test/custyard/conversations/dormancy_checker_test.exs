defmodule Custyard.Conversations.DormancyCheckerTest do
  use Custyard.DataCase, async: true

  alias Custyard.Conversations.DormancyChecker
  alias Custyard.Repo

  import Custyard.Factory

  describe "stale_conversations/0" do
    test "returns waiting conversations past dormancy threshold" do
      org = insert_organization(tier: :standard)
      # Standard threshold is 48 hours
      past_threshold =
        DateTime.utc_now()
        |> DateTime.add(-49, :hour)
        |> DateTime.truncate(:second)

      stale_conv =
        insert_conversation(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: past_threshold
        )

      results = DormancyChecker.stale_conversations()
      ids = Enum.map(results, & &1.id)

      assert stale_conv.id in ids
    end

    test "excludes waiting conversations within threshold" do
      org = insert_organization(tier: :standard)
      # Standard threshold is 48 hours
      within_threshold =
        DateTime.utc_now()
        |> DateTime.add(-24, :hour)
        |> DateTime.truncate(:second)

      _fresh_conv =
        insert_conversation(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: within_threshold
        )

      results = DormancyChecker.stale_conversations()

      assert results == []
    end

    test "excludes active conversations even if old" do
      org = insert_organization(tier: :standard)

      past_threshold =
        DateTime.utc_now()
        |> DateTime.add(-100, :hour)
        |> DateTime.truncate(:second)

      _active_conv =
        insert_conversation(
          organization_id: org.id,
          state: :active,
          last_customer_action_at: past_threshold
        )

      results = DormancyChecker.stale_conversations()

      assert results == []
    end

    test "uses tier-specific thresholds for enterprise" do
      org = insert_organization(tier: :enterprise)
      # Enterprise threshold is 8 hours
      past_enterprise_threshold =
        DateTime.utc_now()
        |> DateTime.add(-9, :hour)
        |> DateTime.truncate(:second)

      stale_conv =
        insert_conversation(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: past_enterprise_threshold
        )

      results = DormancyChecker.stale_conversations()
      ids = Enum.map(results, & &1.id)

      assert stale_conv.id in ids
    end

    test "uses tier-specific thresholds for basic" do
      org = insert_organization(tier: :basic)
      # Basic threshold is 72 hours
      within_basic_threshold =
        DateTime.utc_now()
        |> DateTime.add(-50, :hour)
        |> DateTime.truncate(:second)

      _fresh_conv =
        insert_conversation(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: within_basic_threshold
        )

      results = DormancyChecker.stale_conversations()

      assert results == []
    end

    test "falls back to inserted_at when last_customer_action_at is nil" do
      org = insert_organization(tier: :standard)
      # Create conversation that was inserted 50 hours ago with no customer action
      past_threshold =
        DateTime.utc_now()
        |> DateTime.add(-50, :hour)
        |> DateTime.truncate(:second)

      conv =
        insert_conversation(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: nil
        )

      # Update inserted_at directly since factory sets it to now
      {1, _} =
        Repo.update_all(
          from(c in Custyard.Conversation, where: c.id == ^conv.id),
          set: [inserted_at: past_threshold]
        )

      results = DormancyChecker.stale_conversations()
      ids = Enum.map(results, & &1.id)

      assert conv.id in ids
    end

    test "includes unlinked prospects past the standard-tier cutoff" do
      # Unlinked conversations have no tier; they use the standard cutoff of
      # 48 hours, matching Scoring.neglect_tier/1 and NeglectChecker.
      past_threshold =
        DateTime.utc_now()
        |> DateTime.add(-49, :hour)
        |> DateTime.truncate(:second)

      stale_conv =
        insert_conversation(
          organization_id: nil,
          source: :public_intake,
          state: :waiting,
          last_customer_action_at: past_threshold
        )

      results = DormancyChecker.stale_conversations()
      ids = Enum.map(results, & &1.id)

      assert stale_conv.id in ids
    end

    test "excludes unlinked prospects within the standard-tier cutoff" do
      within_threshold =
        DateTime.utc_now()
        |> DateTime.add(-24, :hour)
        |> DateTime.truncate(:second)

      _fresh_conv =
        insert_conversation(
          organization_id: nil,
          source: :public_intake,
          state: :waiting,
          last_customer_action_at: within_threshold
        )

      results = DormancyChecker.stale_conversations()

      assert results == []
    end

    test "falls back to inserted_at for unlinked prospects with no customer action" do
      past_threshold =
        DateTime.utc_now()
        |> DateTime.add(-50, :hour)
        |> DateTime.truncate(:second)

      conv =
        insert_conversation(
          organization_id: nil,
          source: :public_intake,
          state: :waiting,
          last_customer_action_at: nil
        )

      {1, _} =
        Repo.update_all(
          from(c in Custyard.Conversation, where: c.id == ^conv.id),
          set: [inserted_at: past_threshold]
        )

      results = DormancyChecker.stale_conversations()
      ids = Enum.map(results, & &1.id)

      assert conv.id in ids
    end
  end

  describe "transition_stale_conversations/0" do
    test "transitions stale conversations to dormant" do
      org = insert_organization(tier: :standard)

      past_threshold =
        DateTime.utc_now()
        |> DateTime.add(-49, :hour)
        |> DateTime.truncate(:second)

      conv =
        insert_conversation(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: past_threshold
        )

      count = DormancyChecker.transition_stale_conversations()

      assert count >= 1

      updated = Repo.get!(Custyard.Conversation, conv.id)
      assert updated.state == :dormant
    end

    test "returns count of transitioned conversations" do
      org = insert_organization(tier: :standard)

      past_threshold =
        DateTime.utc_now()
        |> DateTime.add(-49, :hour)
        |> DateTime.truncate(:second)

      insert_conversation(
        organization_id: org.id,
        state: :waiting,
        last_customer_action_at: past_threshold
      )

      insert_conversation(
        organization_id: org.id,
        state: :waiting,
        last_customer_action_at: past_threshold
      )

      count = DormancyChecker.transition_stale_conversations()

      assert count == 2
    end

    test "does not transition fresh waiting conversations" do
      org = insert_organization(tier: :standard)

      recent =
        DateTime.utc_now()
        |> DateTime.add(-1, :hour)
        |> DateTime.truncate(:second)

      conv =
        insert_conversation(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: recent
        )

      count = DormancyChecker.transition_stale_conversations()

      assert count == 0

      unchanged = Repo.get!(Custyard.Conversation, conv.id)
      assert unchanged.state == :waiting
    end

    test "transitions unlinked prospects and broadcasts without an org topic" do
      past_threshold =
        DateTime.utc_now()
        |> DateTime.add(-49, :hour)
        |> DateTime.truncate(:second)

      conv =
        insert_conversation(
          organization_id: nil,
          source: :public_intake,
          state: :waiting,
          last_customer_action_at: past_threshold
        )

      conv_id = conv.id

      Phoenix.PubSub.subscribe(Custyard.PubSub, "conversations")

      count = DormancyChecker.transition_stale_conversations()

      assert count == 1
      assert_receive {:conversation_updated, ^conv_id}, 1000

      updated = Repo.get!(Custyard.Conversation, conv.id)
      assert updated.state == :dormant
    end

    test "broadcasts conversation_updated event for each transition" do
      org = insert_organization(tier: :standard)

      past_threshold =
        DateTime.utc_now()
        |> DateTime.add(-49, :hour)
        |> DateTime.truncate(:second)

      conv =
        insert_conversation(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: past_threshold
        )

      conv_id = conv.id

      # Subscribe to PubSub
      Phoenix.PubSub.subscribe(Custyard.PubSub, "conversations")

      DormancyChecker.transition_stale_conversations()

      assert_receive {:conversation_updated, ^conv_id}, 1000
    end
  end
end
