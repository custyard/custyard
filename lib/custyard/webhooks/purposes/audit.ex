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
  def process(thread, normalized, route_context) do
    attrs = %{
      tenant_id: thread.tenant_id,
      thread_id: thread.id,
      event_type: :webhook_received,
      source: to_string(normalized[:source] || "unknown"),
      message_id: normalized[:message_id],
      payload: build_payload(normalized),
      organization_id: thread.organization_id,
      project_id: thread.project_id
    }

    case AuditEvent.create(attrs) do
      {:ok, _event} ->
        Logger.info(
          "Webhook audit: thread=#{thread.id} " <>
            "source=#{attrs.source} " <>
            "message_id=#{attrs.message_id} " <>
            "org=#{route_context[:organization_id]} " <>
            "project=#{route_context[:project_id]}"
        )

        :ok

      {:error, changeset} ->
        Logger.error(
          "Audit persistence failed for thread #{thread.id}: #{inspect(changeset.errors)}"
        )

        # Still return :ok to avoid blocking the webhook pipeline
        :ok
    end
  rescue
    error ->
      Logger.error("Audit logging failed for thread #{thread.id}: #{inspect(error)}")

      :ok
  end

  # Build a sanitized payload for storage
  # Excludes potentially sensitive raw data, keeps metadata
  defp build_payload(normalized) do
    %{
      source: normalized[:source],
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
