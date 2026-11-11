defmodule Custyard.DraftSubmissionTest do
  use Custyard.DataCase, async: true
  import Custyard.Factory

  alias Custyard.{
    AuditEvent,
    Message,
    MessageDrafts,
    Repo,
    Scope,
    StaffMessageDraft,
    Tenants,
    Threads
  }

  setup do
    staff = insert_staff_account()
    scope = Scope.for_staff(staff, Tenants.get_tenant!(staff.tenant_id))
    thread = insert_thread(source: :public_intake)

    {:ok, draft} =
      MessageDrafts.save(
        scope,
        thread.id,
        %{
          reply_text: "Reply draft",
          note_text: "Private note draft",
          reply_cc: "copy@example.org"
        },
        0
      )

    %{staff: staff, scope: scope, thread: thread, draft: draft}
  end

  test "a committed reply retires its draft even if the caller performs no later write", c do
    assert {:ok, message} =
             Threads.send_reply(c.thread, "Reply draft",
               staff: c.staff,
               expected_draft_version: c.draft.lock_version
             )

    draft = MessageDrafts.get(c.scope, c.thread.id)
    assert draft.reply_text == ""
    assert draft.reply_cc == ""
    refute draft.reply_cc_edited
    assert draft.note_text == "Private note draft"
    assert draft.reviewed_activity_id == message.id
    assert draft.lock_version == c.draft.lock_version + 1
    assert Repo.get!(Message, message.id).body == "Reply draft"
    assert Repo.get_by!(AuditEvent, event_type: :reply_queued)
  end

  test "saving a note retires only its draft and preserves the unsent reply", c do
    assert {:ok, _} =
             Threads.add_internal_note(c.thread, "Private note draft",
               staff: c.staff,
               expected_draft_version: c.draft.lock_version
             )

    draft = MessageDrafts.get(c.scope, c.thread.id)
    assert draft.note_text == ""
    assert draft.reply_text == "Reply draft"
    assert draft.reply_cc == "copy@example.org"
    assert draft.reply_cc_edited
    assert draft.reviewed_activity_id == c.draft.reviewed_activity_id
    assert draft.lock_version == c.draft.lock_version + 1
  end

  test "failed message validation preserves the complete private draft", c do
    for action <- [&Threads.send_reply/3, &Threads.add_internal_note/3] do
      assert {:error, _} =
               action.(c.thread, "",
                 staff: c.staff,
                 expected_draft_version: c.draft.lock_version
               )

      draft = MessageDrafts.get(c.scope, c.thread.id)
      assert draft.reply_text == c.draft.reply_text
      assert draft.note_text == c.draft.note_text
      assert draft.lock_version == c.draft.lock_version
    end

    assert Repo.aggregate(Message, :count) == 0
    assert Repo.aggregate(AuditEvent, :count) == 0
  end

  test "draft retirement failure rolls back message and audit insertion together", c do
    Repo.query!("""
    CREATE TRIGGER fail_draft_retirement BEFORE UPDATE OF reply_text ON staff_message_drafts
    WHEN NEW.reply_text = ''
    BEGIN SELECT RAISE(ABORT, 'retirement failed'); END
    """)

    assert_raise Exqlite.Error, ~r/retirement failed/, fn ->
      Threads.send_reply(c.thread, "Reply draft",
        staff: c.staff,
        expected_draft_version: c.draft.lock_version
      )
    end

    assert Repo.aggregate(Message, :count) == 0
    assert Repo.aggregate(AuditEvent, :count) == 0
    assert Repo.reload!(c.draft).reply_text == "Reply draft"
    assert Repo.reload!(c.draft).lock_version == c.draft.lock_version
  end

  test "a newer draft cannot be overwritten using the submission receipt version", c do
    assert {:ok, _} =
             Threads.send_reply(c.thread, "Reply draft",
               staff: c.staff,
               expected_draft_version: c.draft.lock_version
             )

    submitted_version = c.draft.lock_version + 1

    assert {:ok, newer} =
             MessageDrafts.save(
               c.scope,
               c.thread.id,
               %{reply_text: "New reply from another tab"},
               submitted_version
             )

    assert {:error, :draft_conflict} =
             MessageDrafts.save(c.scope, c.thread.id, %{reply_text: ""}, submitted_version)

    assert Repo.reload!(newer).reply_text == "New reply from another tab"
  end

  test "a direct submission before autosave creates an empty versioned receipt", c do
    Repo.delete!(c.draft)

    assert {:ok, _} =
             Threads.send_reply(c.thread, "Submitted without autosave",
               staff: c.staff,
               expected_draft_version: 0
             )

    assert %StaffMessageDraft{reply_text: "", note_text: "", lock_version: 1} =
             MessageDrafts.get(c.scope, c.thread.id)
  end
end
