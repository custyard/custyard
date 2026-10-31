defmodule Custyard.Acknowledgments.Audit do
  @moduledoc """
  Audit rows for acknowledgment operations. The actor is an operator account
  (the UI) or a channel name: `"cli"` (bin/acknowledgments), `"mix"` or
  `"console"` (a direct call).
  """
  require Custyard.Log, as: Log
  alias Custyard.{AuditEvent, OperatorAccount, Repo}

  @channels ["cli", "mix", "console"]

  @doc "Whether `actor` can be recorded; checked before any work it would audit."
  def actor?(%OperatorAccount{id: id}) when is_integer(id), do: true
  def actor?(channel), do: channel in @channels

  @doc "Inserts the row or raises, for use inside the transaction it audits."
  def record!(event_type, actor, organization_id, payload) do
    {channel, actor_fields} = actor_fields(actor)

    %AuditEvent{}
    |> AuditEvent.changeset(%{
      event_type: event_type,
      source: channel,
      organization_id: organization_id,
      payload: Map.merge(payload, actor_fields)
    })
    |> Repo.insert!()
  end

  @doc """
  Inserts the row after a broker outcome that has already happened (or not),
  so a failed write is logged rather than turned into an error.
  """
  def record(event_type, actor, organization_id, payload) do
    record!(event_type, actor, organization_id, payload)
  rescue
    error ->
      Log.error(
        :acknowledgment_audit_record_failed,
        [event_type: event_type] ++ Log.failure(error)
      )

      :error
  catch
    :exit, _ ->
      Log.error(:acknowledgment_audit_record_failed,
        event_type: event_type,
        reason: :repository_unavailable
      )

      :error
  end

  defp actor_fields(%OperatorAccount{id: id}),
    do: {"operator", %{"actor" => "operator", "operator_id" => id}}

  defp actor_fields(channel) when channel in @channels,
    do: {channel, %{"actor" => channel}}
end
