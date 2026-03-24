defmodule Custyard.Notifications.NeglectChecker do
  @moduledoc """
  Detects when conversations cross neglect thresholds and dispatches notifications.

  This module is called periodically by the Scoring.Scheduler to check for
  conversations that have newly reached warning or critical neglect status.
  Notifications are only sent when a conversation transitions to a higher
  neglect level (ok -> warning, warning -> critical, or ok -> critical).

  Email dispatch is delegated to the `Custyard.Notifications.Email` module,
  which must be configured with an email adapter (e.g., Swoosh).
  """

  import Ecto.Query
  require Logger

  alias Custyard.{Repo, Conversation, Scoring}

  @doc """
  Check all active conversations for neglect threshold breaches and dispatch notifications.

  Returns `{:ok, count}` where count is the number of notifications dispatched.
  """
  def check_and_notify do
    candidates = list_notification_candidates()

    notifications_sent =
      candidates
      |> Enum.map(&check_and_notify_single/1)
      |> Enum.count(& &1)

    {:ok, notifications_sent}
  end

  @doc """
  List conversations that might need neglect notifications.
  Excludes resolved conversations and those currently snoozed.
  """
  def list_notification_candidates do
    now = DateTime.utc_now()

    from(c in Conversation,
      join: o in assoc(c, :organization),
      left_join: ct in assoc(c, :contact),
      where: c.state != :resolved,
      where: is_nil(c.snoozed_until) or c.snoozed_until < ^now,
      preload: [organization: o, contact: ct]
    )
    |> Repo.all()
  end

  defp check_and_notify_single(conversation) do
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
    Custyard.Notifications.Email.deliver_neglect_alert(conversation, level)
  end
end
