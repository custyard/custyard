defmodule Custyard.Webhooks.Purposes.Notification do
  @moduledoc """
  Async staff notification after thread creation/update.

  Sends notifications via configured channels (PubSub for now,
  extensible to Slack, push notifications, email).

  A thread whose sender staff chose to ignore
  (`Custyard.Threads.ignore_sender/2`) notifies nobody.
  """

  alias Custyard.Threads

  require Custyard.Log, as: Log

  @doc """
  Notify staffs about the new/updated thread.
  """
  def process(thread, _normalized, _route_context) do
    # The sender is read here, when the notification would go out, so an
    # ignore set a moment ago already counts.
    if not Threads.sender_ignored?(thread) do
      # Broadcast a notification event for any real-time listeners
      Phoenix.PubSub.broadcast(
        Custyard.PubSub,
        "staff:notifications",
        {:new_message, thread.id}
      )
    end

    :ok
  rescue
    error ->
      Log.error(
        :webhook_notification_failed,
        [thread_id: thread.id] ++ Log.failure(error)
      )

      :ok
  end
end
