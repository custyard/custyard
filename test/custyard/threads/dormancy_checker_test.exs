defmodule Custyard.Threads.DormancyCheckerTest do
  use Custyard.DataCase, async: true

  setup do
    tenant = Custyard.Factory.insert_tenant()
    Process.put(:factory_tenant_id, tenant.id)
    :ok
  end

  defp tenant_id, do: Process.get(:factory_tenant_id)

  alias Custyard.Threads.DormancyChecker
  alias Custyard.Repo

  import Custyard.Factory

  describe "stale_threads/0" do
    test "returns waiting threads past dormancy threshold" do
      org = insert_organization(tier: :standard)
      # Standard threshold is 48 hours
      past_threshold =
        DateTime.utc_now()
        |> DateTime.add(-49, :hour)
        |> DateTime.truncate(:second)

      stale_conv =
        insert_thread(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: past_threshold
        )

      results = DormancyChecker.stale_threads(tenant_id())
      ids = Enum.map(results, & &1.id)

      assert stale_conv.id in ids
    end

    test "excludes waiting threads within threshold" do
      org = insert_organization(tier: :standard)
      # Standard threshold is 48 hours
      within_threshold =
        DateTime.utc_now()
        |> DateTime.add(-24, :hour)
        |> DateTime.truncate(:second)

      _fresh_conv =
        insert_thread(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: within_threshold
        )

      results = DormancyChecker.stale_threads(tenant_id())

      assert results == []
    end

    test "excludes active threads even if old" do
      org = insert_organization(tier: :standard)

      past_threshold =
        DateTime.utc_now()
        |> DateTime.add(-100, :hour)
        |> DateTime.truncate(:second)

      _active_conv =
        insert_thread(
          organization_id: org.id,
          state: :active,
          last_customer_action_at: past_threshold
        )

      results = DormancyChecker.stale_threads(tenant_id())

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
        insert_thread(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: past_enterprise_threshold
        )

      results = DormancyChecker.stale_threads(tenant_id())
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
        insert_thread(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: within_basic_threshold
        )

      results = DormancyChecker.stale_threads(tenant_id())

      assert results == []
    end

    test "falls back to inserted_at when last_customer_action_at is nil" do
      org = insert_organization(tier: :standard)
      # Create thread that was inserted 50 hours ago with no customer action
      past_threshold =
        DateTime.utc_now()
        |> DateTime.add(-50, :hour)
        |> DateTime.truncate(:second)

      conv =
        insert_thread(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: nil
        )

      # Update inserted_at directly since factory sets it to now
      {1, _} =
        Repo.update_all(
          from(c in Custyard.Thread, where: c.id == ^conv.id),
          set: [inserted_at: past_threshold]
        )

      results = DormancyChecker.stale_threads(tenant_id())
      ids = Enum.map(results, & &1.id)

      assert conv.id in ids
    end

    test "includes unlinked prospects past the standard-tier cutoff" do
      # Unlinked threads have no tier; they use the standard cutoff of
      # 48 hours, matching Scoring.neglect_tier/1 and NeglectChecker.
      past_threshold =
        DateTime.utc_now()
        |> DateTime.add(-49, :hour)
        |> DateTime.truncate(:second)

      stale_conv =
        insert_thread(
          organization_id: nil,
          source: :public_intake,
          state: :waiting,
          last_customer_action_at: past_threshold
        )

      results = DormancyChecker.stale_threads(tenant_id())
      ids = Enum.map(results, & &1.id)

      assert stale_conv.id in ids
    end

    test "excludes unlinked prospects within the standard-tier cutoff" do
      within_threshold =
        DateTime.utc_now()
        |> DateTime.add(-24, :hour)
        |> DateTime.truncate(:second)

      _fresh_conv =
        insert_thread(
          organization_id: nil,
          source: :public_intake,
          state: :waiting,
          last_customer_action_at: within_threshold
        )

      results = DormancyChecker.stale_threads(tenant_id())

      assert results == []
    end

    test "falls back to inserted_at for unlinked prospects with no customer action" do
      past_threshold =
        DateTime.utc_now()
        |> DateTime.add(-50, :hour)
        |> DateTime.truncate(:second)

      conv =
        insert_thread(
          organization_id: nil,
          source: :public_intake,
          state: :waiting,
          last_customer_action_at: nil
        )

      {1, _} =
        Repo.update_all(
          from(c in Custyard.Thread, where: c.id == ^conv.id),
          set: [inserted_at: past_threshold]
        )

      results = DormancyChecker.stale_threads(tenant_id())
      ids = Enum.map(results, & &1.id)

      assert conv.id in ids
    end
  end

  describe "transition_stale_threads/0" do
    test "transitions stale threads to dormant" do
      org = insert_organization(tier: :standard)

      past_threshold =
        DateTime.utc_now()
        |> DateTime.add(-49, :hour)
        |> DateTime.truncate(:second)

      conv =
        insert_thread(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: past_threshold
        )

      count = DormancyChecker.transition_stale_threads()

      assert count >= 1

      updated = Repo.get!(Custyard.Thread, conv.id)
      assert updated.state == :dormant
    end

    test "returns count of transitioned threads" do
      org = insert_organization(tier: :standard)

      past_threshold =
        DateTime.utc_now()
        |> DateTime.add(-49, :hour)
        |> DateTime.truncate(:second)

      insert_thread(
        organization_id: org.id,
        state: :waiting,
        last_customer_action_at: past_threshold
      )

      insert_thread(
        organization_id: org.id,
        state: :waiting,
        last_customer_action_at: past_threshold
      )

      count = DormancyChecker.transition_stale_threads()

      assert count == 2
    end

    test "does not transition fresh waiting threads" do
      org = insert_organization(tier: :standard)

      recent =
        DateTime.utc_now()
        |> DateTime.add(-1, :hour)
        |> DateTime.truncate(:second)

      conv =
        insert_thread(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: recent
        )

      count = DormancyChecker.transition_stale_threads()

      assert count == 0

      unchanged = Repo.get!(Custyard.Thread, conv.id)
      assert unchanged.state == :waiting
    end

    test "transitions unlinked prospects and broadcasts without an org topic" do
      past_threshold =
        DateTime.utc_now()
        |> DateTime.add(-49, :hour)
        |> DateTime.truncate(:second)

      conv =
        insert_thread(
          organization_id: nil,
          source: :public_intake,
          state: :waiting,
          last_customer_action_at: past_threshold
        )

      conv_id = conv.id

      Phoenix.PubSub.subscribe(Custyard.PubSub, "threads")

      count = DormancyChecker.transition_stale_threads()

      assert count == 1
      assert_receive {:thread_updated, ^conv_id}, 1000

      updated = Repo.get!(Custyard.Thread, conv.id)
      assert updated.state == :dormant
    end

    test "broadcasts thread_updated event for each transition" do
      org = insert_organization(tier: :standard)

      past_threshold =
        DateTime.utc_now()
        |> DateTime.add(-49, :hour)
        |> DateTime.truncate(:second)

      conv =
        insert_thread(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: past_threshold
        )

      conv_id = conv.id

      # Subscribe to PubSub
      Phoenix.PubSub.subscribe(Custyard.PubSub, "threads")

      DormancyChecker.transition_stale_threads()

      assert_receive {:thread_updated, ^conv_id}, 1000
    end
  end

  describe "staff activity" do
    test "a thread the staff replied to within the threshold is not stale" do
      org = insert_organization(tier: :standard)

      past_threshold =
        DateTime.utc_now() |> DateTime.add(-49, :hour) |> DateTime.truncate(:second)

      recent = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)

      conv =
        insert_thread(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: past_threshold,
          last_staff_action_at: recent
        )

      refute conv.id in Enum.map(DormancyChecker.stale_threads(tenant_id()), & &1.id)
    end

    test "a thread quiet on both sides past the threshold is stale" do
      org = insert_organization(tier: :standard)

      past_threshold =
        DateTime.utc_now() |> DateTime.add(-49, :hour) |> DateTime.truncate(:second)

      conv =
        insert_thread(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: past_threshold,
          last_staff_action_at: past_threshold
        )

      assert conv.id in Enum.map(DormancyChecker.stale_threads(tenant_id()), & &1.id)
    end

    test "transition only applies to rows still waiting" do
      org = insert_organization(tier: :standard)

      past_threshold =
        DateTime.utc_now() |> DateTime.add(-49, :hour) |> DateTime.truncate(:second)

      conv =
        insert_thread(
          organization_id: org.id,
          state: :waiting,
          last_customer_action_at: past_threshold
        )

      assert DormancyChecker.transition_stale_threads() == 1
      assert Custyard.Repo.get!(Custyard.Thread, conv.id).state == :dormant
      # The row is no longer waiting, so a second pass changes nothing.
      assert DormancyChecker.transition_stale_threads() == 0
    end
  end
end
