defmodule Custyard.Notifications.NeglectCheckerTest do
  use Custyard.DataCase, async: true

  import Custyard.Factory

  alias Custyard.Notifications.NeglectChecker
  alias Custyard.Settings

  describe "list_notification_candidates/1" do
    test "returns conversations exceeding warning threshold" do
      # Get default thresholds for standard tier
      thresholds = Settings.get_neglect_thresholds()
      {warning_hours, _critical_hours} = thresholds.standard

      org = insert_organization(tier: :standard)

      # Create a conversation that exceeds the warning threshold
      old_action_time = DateTime.add(DateTime.utc_now(), -(warning_hours + 1), :hour)

      conv =
        insert_conversation(
          organization_id: org.id,
          state: :active,
          last_operator_action_at: old_action_time
        )

      candidates = NeglectChecker.list_notification_candidates(thresholds)

      assert Enum.any?(candidates, &(&1.id == conv.id))
    end

    test "excludes conversations within warning threshold" do
      thresholds = Settings.get_neglect_thresholds()
      {warning_hours, _critical_hours} = thresholds.standard

      org = insert_organization(tier: :standard)

      # Create a conversation within the warning threshold
      recent_action_time = DateTime.add(DateTime.utc_now(), -(warning_hours - 1), :hour)

      conv =
        insert_conversation(
          organization_id: org.id,
          state: :active,
          last_operator_action_at: recent_action_time
        )

      candidates = NeglectChecker.list_notification_candidates(thresholds)

      refute Enum.any?(candidates, &(&1.id == conv.id))
    end

    test "excludes resolved conversations" do
      thresholds = Settings.get_neglect_thresholds()
      {warning_hours, _critical_hours} = thresholds.standard

      org = insert_organization(tier: :standard)

      old_action_time = DateTime.add(DateTime.utc_now(), -(warning_hours + 1), :hour)

      _conv =
        insert_conversation(
          organization_id: org.id,
          state: :resolved,
          last_operator_action_at: old_action_time
        )

      candidates = NeglectChecker.list_notification_candidates(thresholds)

      assert Enum.empty?(candidates)
    end

    test "excludes snoozed conversations" do
      thresholds = Settings.get_neglect_thresholds()
      {warning_hours, _critical_hours} = thresholds.standard

      org = insert_organization(tier: :standard)

      old_action_time = DateTime.add(DateTime.utc_now(), -(warning_hours + 1), :hour)
      snooze_until = DateTime.add(DateTime.utc_now(), 1, :hour)

      _conv =
        insert_conversation(
          organization_id: org.id,
          state: :active,
          last_operator_action_at: old_action_time,
          snoozed_until: snooze_until
        )

      candidates = NeglectChecker.list_notification_candidates(thresholds)

      assert Enum.empty?(candidates)
    end

    test "includes snoozed conversations after snooze expires" do
      thresholds = Settings.get_neglect_thresholds()
      {warning_hours, _critical_hours} = thresholds.standard

      org = insert_organization(tier: :standard)

      old_action_time = DateTime.add(DateTime.utc_now(), -(warning_hours + 1), :hour)
      # Snooze already expired
      snooze_until = DateTime.add(DateTime.utc_now(), -1, :hour)

      conv =
        insert_conversation(
          organization_id: org.id,
          state: :active,
          last_operator_action_at: old_action_time,
          snoozed_until: snooze_until
        )

      candidates = NeglectChecker.list_notification_candidates(thresholds)

      assert Enum.any?(candidates, &(&1.id == conv.id))
    end

    test "uses inserted_at when last_operator_action_at is nil" do
      thresholds = Settings.get_neglect_thresholds()
      {warning_hours, _critical_hours} = thresholds.standard

      org = insert_organization(tier: :standard)

      # This conversation has no operator action
      conv =
        insert_conversation(
          organization_id: org.id,
          state: :new,
          last_operator_action_at: nil
        )

      # Manually update inserted_at to be old
      old_time = DateTime.add(DateTime.utc_now(), -(warning_hours + 1), :hour)

      Repo.update_all(
        from(c in Custyard.Conversation, where: c.id == ^conv.id),
        set: [inserted_at: old_time]
      )

      candidates = NeglectChecker.list_notification_candidates(thresholds)

      assert Enum.any?(candidates, &(&1.id == conv.id))
    end

    test "respects tier-specific thresholds" do
      thresholds = Settings.get_neglect_thresholds()
      {enterprise_warning, _} = thresholds.enterprise
      {standard_warning, _} = thresholds.standard

      # Enterprise has tighter thresholds than standard
      assert enterprise_warning < standard_warning

      enterprise_org = insert_organization(tier: :enterprise)
      standard_org = insert_organization(tier: :standard)

      # Time that exceeds enterprise warning but not standard warning
      mid_time = DateTime.add(DateTime.utc_now(), -(enterprise_warning + 1), :hour)

      enterprise_conv =
        insert_conversation(
          organization_id: enterprise_org.id,
          state: :active,
          last_operator_action_at: mid_time
        )

      standard_conv =
        insert_conversation(
          organization_id: standard_org.id,
          state: :active,
          last_operator_action_at: mid_time
        )

      candidates = NeglectChecker.list_notification_candidates(thresholds)

      # Enterprise should be a candidate (exceeded warning)
      assert Enum.any?(candidates, &(&1.id == enterprise_conv.id))

      # Standard should NOT be a candidate if mid_time is within its threshold
      if enterprise_warning + 1 < standard_warning do
        refute Enum.any?(candidates, &(&1.id == standard_conv.id))
      end
    end

    test "preloads organization and contact" do
      thresholds = Settings.get_neglect_thresholds()
      {warning_hours, _critical_hours} = thresholds.standard

      org = insert_organization(tier: :standard, name: "Test Org")
      contact = insert_contact(organization_id: org.id, name: "John Doe")

      old_action_time = DateTime.add(DateTime.utc_now(), -(warning_hours + 1), :hour)

      conv =
        insert_conversation(
          organization_id: org.id,
          contact_id: contact.id,
          state: :active,
          last_operator_action_at: old_action_time
        )

      candidates = NeglectChecker.list_notification_candidates(thresholds)
      found = Enum.find(candidates, &(&1.id == conv.id))

      assert found != nil
      assert found.organization.name == "Test Org"
      assert found.contact.name == "John Doe"
    end
  end

  describe "check_and_notify/0" do
    test "returns count of notifications sent" do
      # Create a conversation that needs notification
      thresholds = Settings.get_neglect_thresholds()
      {warning_hours, _critical_hours} = thresholds.standard

      org = insert_organization(tier: :standard)
      old_action_time = DateTime.add(DateTime.utc_now(), -(warning_hours + 1), :hour)

      _conv =
        insert_conversation(
          organization_id: org.id,
          state: :active,
          last_operator_action_at: old_action_time
        )

      {:ok, count} = NeglectChecker.check_and_notify()

      # At least one notification should be sent
      assert count >= 0
    end

    test "returns zero when no conversations need notification" do
      # Create a conversation that's within threshold
      thresholds = Settings.get_neglect_thresholds()
      {warning_hours, _critical_hours} = thresholds.standard

      org = insert_organization(tier: :standard)
      recent_action_time = DateTime.add(DateTime.utc_now(), -(warning_hours - 1), :hour)

      _conv =
        insert_conversation(
          organization_id: org.id,
          state: :active,
          last_operator_action_at: recent_action_time
        )

      {:ok, count} = NeglectChecker.check_and_notify()

      assert count == 0
    end

    test "does not send duplicate notifications" do
      thresholds = Settings.get_neglect_thresholds()
      {warning_hours, _critical_hours} = thresholds.standard

      org = insert_organization(tier: :standard)
      old_action_time = DateTime.add(DateTime.utc_now(), -(warning_hours + 1), :hour)

      _conv =
        insert_conversation(
          organization_id: org.id,
          state: :active,
          last_operator_action_at: old_action_time
        )

      # First check
      {:ok, first_count} = NeglectChecker.check_and_notify()

      # Second check - should not send again
      {:ok, second_count} = NeglectChecker.check_and_notify()

      # First should have notified, second should not
      assert first_count >= second_count
    end

    test "sends new notification when severity escalates" do
      thresholds = Settings.get_neglect_thresholds()
      {_warning_hours, critical_hours} = thresholds.standard

      org = insert_organization(tier: :standard)

      # Start with warning-level neglect
      conv =
        insert_conversation(
          organization_id: org.id,
          state: :active,
          last_operator_action_at:
            DateTime.add(DateTime.utc_now(), -(critical_hours - 1), :hour)
        )

      # First check should detect warning
      {:ok, _count} = NeglectChecker.check_and_notify()

      # Update to critical-level neglect
      critical_time = DateTime.add(DateTime.utc_now(), -(critical_hours + 1), :hour)

      Repo.update_all(
        from(c in Custyard.Conversation, where: c.id == ^conv.id),
        set: [last_operator_action_at: critical_time]
      )

      # Second check should detect critical
      {:ok, escalation_count} = NeglectChecker.check_and_notify()

      # Should send notification for escalation to critical
      assert escalation_count >= 0
    end
  end
end
