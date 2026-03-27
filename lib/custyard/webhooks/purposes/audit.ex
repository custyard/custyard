defmodule Custyard.Webhooks.Purposes.Audit do
  @moduledoc """
  Append-only audit log for webhook events.

  Records all inbound webhook activity for compliance and debugging.
  Persists events to the audit_events table for queryability.
  Tolerates duplicates using message_id as a deduplication key at query time.
  """

  require Logger

  alias Custyard.AuditEvent

  @doc """
  Log the webhook event for audit purposes.

  Persists the event to the database and logs to Logger for real-time visibility.
  """
  def process(conversation, normalized, route_context) do
    attrs = %{
      conversation_id: conversation.id,
      event_type: :webhook_received,
      source: to_string(normalized[:source] || "unknown"),
      message_id: normalized[:message_id],
      payload: build_payload(normalized),
      organization_id: route_context[:organization_id],
      project_id: route_context[:project_id]
    }

    case AuditEvent.create(attrs) do
      {:ok, _event} ->
        Logger.info(
          "Webhook audit: conversation=#{conversation.id} " <>
            "source=#{attrs.source} " <>
            "message_id=#{attrs.message_id} " <>
            "org=#{route_context[:organization_id]} " <>
            "project=#{route_context[:project_id]}"
        )

        :ok

      {:error, changeset} ->
        Logger.error(
          "Audit persistence failed for conversation #{conversation.id}: #{inspect(changeset.errors)}"
        )

        # Still return :ok to avoid blocking the webhook pipeline
        :ok
    end
  rescue
    error ->
      Logger.error(
        "Audit logging failed for conversation #{conversation.id}: #{inspect(error)}"
      )

      :ok
  end

  # Build a sanitized payload for storage
  # Excludes potentially sensitive raw data, keeps metadata
  defp build_payload(normalized) do
    %{
      source: normalized[:source],
      sender_email: normalized[:sender_email],
      subject: normalized[:subject],
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
