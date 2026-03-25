defmodule Custyard.Webhooks.Purposes.Audit do
  @moduledoc """
  Append-only audit log for webhook events.

  Records all inbound webhook activity for compliance and debugging.
  Tolerates duplicates using message_id as a deduplication key at query time.
  """

  require Logger

  @doc """
  Log the webhook event for audit purposes.
  """
  def process(conversation, normalized, route_context) do
    Logger.info(
      "Webhook audit: conversation=#{conversation.id} " <>
        "source=#{normalized[:source]} " <>
        "message_id=#{normalized.message_id} " <>
        "org=#{route_context[:organization_id]} " <>
        "project=#{route_context[:project_id]}"
    )

    :ok
  rescue
    error ->
      Logger.error("Audit logging failed for conversation #{conversation.id}: #{inspect(error)}")
      :ok
  end
end
