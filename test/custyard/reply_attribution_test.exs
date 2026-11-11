defmodule Custyard.ReplyAttributionTest do
  use Custyard.DataCase, async: false

  import Custyard.Factory
  alias Custyard.{AuditEvent, Message, MessageDrafts, Repo, StaffAccount, Threads}
  alias Custyard.Email.Outbound
  alias Ecto.Adapters.SQL

  setup do
    tenant = insert_tenant()
    Process.put(:factory_tenant_id, tenant.id)
    staff = insert_staff_account(tenant_id: tenant.id)
    thread = insert_thread(tenant_id: tenant.id, source: :public_intake)
    %{tenant: tenant, staff: staff, thread: thread}
  end

  test "replies retain their human author separately from the From identity", %{
    staff: staff,
    thread: thread
  } do
    assert {:ok, message} = Threads.send_reply(thread, "Private body", staff: staff)
    assert message.author_staff_id == staff.id
    assert message.sender_email != staff.email

    assert %AuditEvent{payload: payload, thread_id: thread_id, tenant_id: tenant_id} =
             Repo.get_by!(AuditEvent, event_type: :reply_queued)

    assert thread_id == thread.id
    assert tenant_id == thread.tenant_id
    assert payload == %{"actor" => "staff", "staff_id" => staff.id, "message_db_id" => message.id}
    refute inspect(payload) =~ "Private body"
    refute inspect(payload) =~ staff.email

    scope = Custyard.Scope.for_staff(staff, Custyard.Tenants.get_tenant!(staff.tenant_id))

    assert [%{author_staff: %StaffAccount{id: author_id}}] =
             Threads.get_with_messages(scope, thread.id).messages

    assert author_id == staff.id
  end

  test "notes use authenticated authors and create one atomic audit event", %{
    staff: staff,
    thread: thread
  } do
    assert {:ok, note} = Threads.add_internal_note(thread, "Keep private", staff: staff)
    assert note.is_internal_note
    assert note.author_staff_id == staff.id
    assert is_nil(note.delivery_status)
    assert [] == Threads.list_public_messages(thread.id)

    assert %{payload: %{"staff_id" => staff_id, "message_db_id" => message_id}} =
             Repo.get_by!(AuditEvent, event_type: :internal_note_created)

    assert staff_id == staff.id
    assert message_id == note.id

    assert {:error, _} = Threads.add_internal_note(thread, "", staff: staff)
    assert Repo.aggregate(AuditEvent, :count) == 1
    assert Repo.aggregate(Message, :count) == 1
  end

  test "untrusted attrs cannot forge an author", %{staff: staff, thread: thread} do
    attrs = %{
      source: :staff,
      body: "Unattributed system record",
      thread_id: thread.id,
      author_staff_id: staff.id
    }

    assert {:ok, message} = Threads.create_message(attrs)
    assert is_nil(message.author_staff_id)
    assert {:error, :unauthorized} = Threads.add_internal_note(thread, "Note", [])
  end

  test "revoked sessions cannot submit replies or notes", %{staff: staff, thread: thread} do
    staff
    |> Ecto.Changeset.change(session_claim: StaffAccount.generate_session_claim())
    |> Repo.update!()

    assert {:error, :unauthorized} = Threads.send_reply(thread, "Reply", staff: staff)
    assert {:error, :unauthorized} = Threads.add_internal_note(thread, "Note", staff: staff)
    assert Repo.aggregate(Message, :count) == 0
    assert Repo.aggregate(AuditEvent, :count) == 0
  end

  test "foreign tenant authors are rejected by contexts and database constraints", %{
    staff: staff,
    thread: thread
  } do
    foreign = insert_staff_account(tenant_id: insert_tenant().id)
    assert {:error, :unauthorized} = Threads.send_reply(thread, "Reply", staff: foreign)
    assert {:error, :unauthorized} = Threads.add_internal_note(thread, "Note", staff: foreign)

    {:ok, message} = Threads.send_reply(thread, "Own reply", staff: staff)

    assert {:error, _} =
             SQL.query(Repo, "UPDATE messages SET author_staff_id = ? WHERE id = ?", [
               foreign.id,
               message.id
             ])

    assert {:error, _} =
             SQL.query(Repo, "UPDATE staff_accounts SET tenant_id = ? WHERE id = ?", [
               foreign.tenant_id,
               staff.id
             ])
  end

  test "deleting a staff account preserves the message and actor audit ID", %{
    staff: staff,
    thread: thread
  } do
    {:ok, message} = Threads.send_reply(thread, "Historical reply", staff: staff)
    Repo.delete!(staff)
    assert is_nil(Repo.reload!(message).author_staff_id)
    assert Repo.reload!(message).body == "Historical reply"
    assert Repo.get_by!(AuditEvent, event_type: :reply_queued).payload["staff_id"] == staff.id
  end

  test "retry records its current actor without changing the original author", c do
    configure_tenant_email(c.tenant.id)
    contact = insert_contact(tenant_id: c.tenant.id)

    thread =
      insert_thread(
        tenant_id: c.tenant.id,
        organization_id: contact.organization_id,
        contact_id: contact.id
      )

    {:ok, original} = Threads.send_reply(thread, "Original reply", staff: c.staff)

    failed =
      original
      |> Message.delivery_status_changeset(:failed, %{
        delivery_failure_kind: :configuration,
        delivery_error_code: "configuration"
      })
      |> Repo.update!()

    retrying = insert_staff_account(tenant_id: c.tenant.id)
    scope = Custyard.Scope.for_staff(retrying, c.tenant)

    assert {:ok, retried} =
             Outbound.retry(scope, failed, staff: c.staff, author_staff_id: retrying.id)

    assert retried.author_staff_id == c.staff.id
    assert retried.id == original.id
    assert retried.body == original.body
    assert Repo.get_by!(AuditEvent, event_type: :reply_retried).payload["staff_id"] == retrying.id
  end

  test "foreign and revoked retry actors cannot create send audit records", c do
    failed =
      insert_message(
        thread_id: c.thread.id,
        source: :staff,
        delivery_status: :failed
      )
      |> Message.delivery_status_changeset(:failed, %{
        delivery_failure_kind: :configuration,
        delivery_error_code: "configuration"
      })
      |> Repo.update!()

    other_tenant = insert_tenant()
    foreign = insert_staff_account(tenant_id: other_tenant.id)

    assert {:error, :unauthorized} =
             Outbound.retry(Custyard.Scope.for_staff(foreign, other_tenant), failed)

    scope = Custyard.Scope.for_staff(c.staff, c.tenant)

    c.staff
    |> Ecto.Changeset.change(session_claim: StaffAccount.generate_session_claim())
    |> Repo.update!()

    assert {:error, :unauthorized} = Outbound.retry(scope, failed)
    assert Repo.aggregate(AuditEvent, :count) == 0
    assert Repo.reload!(failed).delivery_status == :failed
  end

  test "new activity blocks a stale composer even when its recipient did not change", %{
    staff: staff,
    thread: thread
  } do
    assert Threads.latest_activity_id(thread.id) == 0
    note = insert_message(thread_id: thread.id, source: :staff, is_internal_note: true)

    assert {:error, :conversation_changed} =
             Threads.send_reply(thread, "Stale draft", staff: staff, expected_activity_id: 0)

    assert Repo.aggregate(Message, :count) == 1

    assert {:ok, _} =
             Threads.send_reply(thread, "Reviewed draft",
               staff: staff,
               expected_activity_id: note.id
             )
  end

  test "reply and note submissions verify the stored draft version before insertion", c do
    scope = Custyard.Scope.for_staff(c.staff, c.tenant)
    assert {:ok, draft} = MessageDrafts.save(scope, c.thread.id, %{reply_text: "First"}, 0)

    assert {:ok, updated} =
             MessageDrafts.save(
               scope,
               c.thread.id,
               %{reply_text: "Another tab"},
               draft.lock_version
             )

    for version <- [0, draft.lock_version] do
      opts = [staff: c.staff, expected_draft_version: version]
      assert {:error, :draft_conflict} = Threads.send_reply(c.thread, "Outdated", opts)
      assert {:error, :draft_conflict} = Threads.add_internal_note(c.thread, "Outdated", opts)
    end

    assert Repo.aggregate(Message, :count) == 0
    assert Repo.aggregate(AuditEvent, :count) == 0

    assert {:ok, _} =
             Threads.add_internal_note(c.thread, "Reviewed",
               staff: c.staff,
               expected_draft_version: updated.lock_version
             )

    Repo.delete!(updated)

    assert {:error, :draft_conflict} =
             Threads.send_reply(c.thread, "Erased draft",
               staff: c.staff,
               expected_draft_version: updated.lock_version
             )
  end
end
