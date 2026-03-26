defmodule Custyard.Webhooks.Purposes.Notification do
  @moduledoc """
  Async operator notification after conversation creation/update.

  Sends notifications via configured channels (PubSub for now,
  extensible to Slack, push notifications, email).
  """

  require Logger

  @doc """
  Notify operators about the new/updated conversation.
  """
  def process(conversation, _normalized, _route_context) do
    # Broadcast a notification event for any real-time listeners
    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "operator:notifications",
      {:new_message, conversation.id}
    )

    :ok
  rescue
    error ->
      Logger.error("Notification failed for conversation #{conversation.id}: #{inspect(error)}")
      :ok
  end
end
