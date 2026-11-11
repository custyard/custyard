defmodule Custyard.Email.ReplyAudit do
  @moduledoc "Minimal, transactional audit records for human reply and note actions."

  alias Custyard.{AuditEvent, Message, Repo, StaffAccount, Thread}

  @events [:reply_queued, :internal_note_created, :reply_retried]

  @doc "Insert inside the action's transaction; never record message bodies or addresses."
  def record!(event_type, %Message{} = message, %Thread{} = thread, staff)
      when event_type in @events do
    payload = Map.put(actor(staff), "message_db_id", message.id)

    %AuditEvent{}
    |> AuditEvent.changeset(%{
      tenant_id: thread.tenant_id,
      thread_id: thread.id,
      event_type: event_type,
      source: if(staff, do: "staff", else: "system"),
      payload: payload
    })
    |> Repo.insert!()
  end

  defp actor(%StaffAccount{id: id}), do: %{"actor" => "staff", "staff_id" => id}
  defp actor(nil), do: %{"actor" => "system"}
end
