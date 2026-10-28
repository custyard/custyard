defmodule Custyard.Webhooks.Purposes.Notification do
  @moduledoc """
  Async staff notification after thread creation/update.

  Sends notifications via configured channels (PubSub for now,
  extensible to Slack, push notifications, email).
  """

  require Logger

  @doc """
  Notify staffs about the new/updated thread.
  """
  def process(thread, _normalized, _route_context) do
    # Broadcast a notification event for any real-time listeners
    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "staff:notifications",
      {:new_message, thread.id}
    )

    :ok
  rescue
    error ->
      Logger.error("Notification failed for thread #{thread.id}: #{inspect(error)}")
      :ok
  end
end
