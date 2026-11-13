defmodule Custyard.Threads.ActionAudit do
  @moduledoc """
  Audit records for what staff do to a thread outside its messages: changing
  its state and ignoring its sender.

  Each record is inserted inside the action's own transaction, so the change
  and the record of who made it are stored together or not at all. Payloads
  hold internal ids and state names only, never an address or a subject.
  """

  alias Custyard.{AuditEvent, Contact, Repo, StaffAccount, Thread}

  @doc """
  Record that `staff` moved a thread from the state of `before` to the state
  of `updated`. Nothing is recorded when the state is the same.
  """
  def state_changed!(%Thread{state: state}, %Thread{state: state}, %StaffAccount{}), do: :ok

  def state_changed!(%Thread{} = before, %Thread{} = updated, %StaffAccount{} = staff) do
    insert!(updated, :thread_state_changed, %{
      "staff_id" => staff.id,
      "from" => Atom.to_string(before.state),
      "to" => Atom.to_string(updated.state)
    })
  end

  @doc """
  Record that `staff` started (`true`) or stopped (`false`) ignoring
  `contact`, the sender of `thread`.
  """
  def sender_ignored!(%Thread{} = thread, %Contact{} = contact, %StaffAccount{} = staff, ignored?)
      when is_boolean(ignored?) do
    insert!(thread, :sender_ignored, %{
      "staff_id" => staff.id,
      "contact_id" => contact.id,
      "ignored" => ignored?
    })
  end

  defp insert!(%Thread{} = thread, event_type, payload) do
    %AuditEvent{}
    |> AuditEvent.changeset(%{
      tenant_id: thread.tenant_id,
      thread_id: thread.id,
      organization_id: thread.organization_id,
      event_type: event_type,
      source: "staff",
      payload: payload
    })
    |> Repo.insert!()

    :ok
  end
end
