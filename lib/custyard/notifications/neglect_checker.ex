defmodule Custyard.Notifications.NeglectChecker do
  @moduledoc """
  Detects when conversations cross neglect thresholds and dispatches notifications.

  This module is called periodically by the Scoring.Scheduler to check for
  conversations that have newly reached warning or critical neglect status.
  Notifications are only sent when a conversation transitions to a higher
  neglect level (ok -> warning, warning -> critical, or ok -> critical).

  Email dispatch is delegated to the `Custyard.Notifications.Email` module,
  which must be configured with an email adapter (e.g., Swoosh).

  The query is optimized to only load conversations that have exceeded at least
  one neglect threshold, avoiding full table scans in deployments with many
  active conversations.
  """

  import Ecto.Query
  require Logger

  alias Custyard.{Conversation, Repo, Settings}
  alias Custyard.Notifications.Email, as: NotificationEmail

  @doc """
  Check all active conversations for neglect threshold breaches and dispatch notifications.

  Returns `{:ok, count}` where count is the number of notifications dispatched.
  """
  def check_and_notify do
    # Load thresholds once for all candidates to avoid repeated Settings calls
    thresholds = Settings.get_neglect_thresholds()
    candidates = list_notification_candidates(thresholds)

    notifications_sent =
      candidates
      |> Enum.map(&check_and_notify_single(&1, thresholds))
      |> Enum.count(& &1)

    {:ok, notifications_sent}
  end

  @doc """
  List conversations that might need neglect notifications.

  Only loads conversations that have exceeded at least the warning threshold
  for their organization's tier. This is optimized to avoid loading all
  active conversations on every check.

  Excludes:
  - Resolved conversations (no longer need attention)
  - Currently snoozed conversations
  - Conversations with nil organization (disambiguation conversations)
  """
  def list_notification_candidates(thresholds \\ nil) do
    now = DateTime.utc_now()

    # Use provided thresholds or load from Settings
    thresholds = thresholds || Settings.get_neglect_thresholds()
    {enterprise_warning, _} = thresholds.enterprise
    {standard_warning, _} = thresholds.standard
    {basic_warning, _} = thresholds.basic

    enterprise_cutoff = hours_ago(enterprise_warning)
    standard_cutoff = hours_ago(standard_warning)
    basic_cutoff = hours_ago(basic_warning)

    from(c in Conversation,
      join: o in assoc(c, :organization),
      left_join: ct in assoc(c, :contact),
      where: c.state != :resolved,
      where: is_nil(c.snoozed_until) or c.snoozed_until < ^now,
      # Only load conversations that have exceeded their tier's warning threshold
      # This is the key optimization - we filter in the DB instead of loading all
      where:
        (o.tier == :enterprise and
           coalesce(c.last_operator_action_at, c.inserted_at) <= ^enterprise_cutoff) or
          (o.tier == :standard and
             coalesce(c.last_operator_action_at, c.inserted_at) <= ^standard_cutoff) or
          (o.tier == :basic and
             coalesce(c.last_operator_action_at, c.inserted_at) <= ^basic_cutoff),
      preload: [organization: o, contact: ct]
    )
    |> Repo.all()
  end

  defp hours_ago(hours) do
    DateTime.add(DateTime.utc_now(), -hours, :hour)
  end

  defp check_and_notify_single(conversation, _thresholds) do
    alias Custyard.Scoring
    current_status = Scoring.neglect_status(conversation)
    last_notified = conversation.last_neglect_notification

    cond do
      # No notification needed for :ok status
      current_status == :ok ->
        # If we previously notified, reset the tracking
        if last_notified do
          update_notification_tracking(conversation, nil)
        end

        false

      # Already notified at this level or higher
      notification_already_sent?(last_notified, current_status) ->
        false

      # New threshold breach - send notification
      true ->
        dispatch_notification(conversation, current_status)
        update_notification_tracking(conversation, current_status)
        true
    end
  end

  defp notification_already_sent?(nil, _current), do: false
  defp notification_already_sent?(:ok, _current), do: false
  defp notification_already_sent?(:warning, :warning), do: true
  defp notification_already_sent?(:critical, :warning), do: true
  defp notification_already_sent?(:critical, :critical), do: true
  defp notification_already_sent?(:warning, :critical), do: false

  defp update_notification_tracking(conversation, level) do
    conversation
    |> Ecto.Changeset.change(last_neglect_notification: level)
    |> Repo.update!()
  end

  defp dispatch_notification(conversation, level) do
    Logger.info(
      "Neglect notification: conversation #{conversation.id} (#{conversation.subject}) " <>
        "reached #{level} for org #{conversation.organization.name}"
    )

    # Delegate to email module when configured
    # This will be a no-op if email is not configured
    NotificationEmail.deliver_neglect_alert(conversation, level)
  end
end
