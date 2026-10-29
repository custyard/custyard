defmodule Custyard.MessageDraftsTest do
  use Custyard.DataCase, async: true
  import Custyard.Factory
  alias Custyard.{MessageDrafts, Repo, Scope, StaffAccount, StaffMessageDraft, Tenants}

  setup do
    staff = insert_staff_account()
    scope = Scope.for_staff(staff, Tenants.get_tenant!(staff.tenant_id))
    thread = insert_thread(organization_id: insert_organization().id)
    %{staff: staff, scope: scope, thread: thread}
  end

  test "drafts are private to staff, reject foreign resources and invalidated sessions", c do
    assert {:ok, saved} =
             MessageDrafts.save(
               c.scope,
               c.thread.id,
               %{reply_text: "Reply", note_text: "Private"},
               0
             )

    other = insert_staff_account()
    other_scope = Scope.for_staff(other, Tenants.get_tenant!(other.tenant_id))
    assert is_nil(MessageDrafts.get(other_scope, c.thread.id))
    foreign = insert_tenant()

    foreign_thread =
      insert_thread(
        tenant_id: foreign.id,
        organization_id: insert_organization(tenant_id: foreign.id).id
      )

    assert {:error, :unauthorized} =
             MessageDrafts.save(c.scope, foreign_thread.id, %{reply_text: "Leak"}, 0)

    assert is_nil(MessageDrafts.get(c.scope, foreign_thread.id))

    Repo.update!(
      Ecto.Changeset.change(c.staff, session_claim: StaffAccount.generate_session_claim())
    )

    assert is_nil(MessageDrafts.get(c.scope, c.thread.id))

    assert {:error, :unauthorized} =
             MessageDrafts.save(c.scope, c.thread.id, %{note_text: "Changed"}, saved.lock_version)
  end

  test "concurrent tabs cannot overwrite a saved draft", c do
    assert {:ok, saved} = MessageDrafts.save(c.scope, c.thread.id, %{reply_text: "First"}, 0)

    assert {:error, :draft_conflict} =
             MessageDrafts.save(c.scope, c.thread.id, %{reply_text: "Other tab"}, 0)

    assert {:ok, updated} =
             MessageDrafts.save(
               c.scope,
               c.thread.id,
               %{note_text: "Separate note"},
               saved.lock_version
             )

    assert {:error, :draft_conflict} =
             MessageDrafts.save(c.scope, c.thread.id, %{reply_text: "Stale"}, saved.lock_version)

    assert updated.reply_text == "First"
    assert updated.note_text == "Separate note"
  end

  test "CC values supplied by context callers record explicit recipient intent", c do
    assert {:ok, draft} =
             MessageDrafts.save(c.scope, c.thread.id, %{reply_cc: "copy@example.org"}, 0)

    assert draft.reply_cc_edited

    assert {:ok, empty} =
             MessageDrafts.save(c.scope, c.thread.id, %{"reply_cc" => ""}, draft.lock_version)

    assert empty.reply_cc_edited

    assert {:ok, automatic} =
             MessageDrafts.save(
               c.scope,
               c.thread.id,
               %{reply_cc: "default@example.org", reply_cc_edited: false},
               empty.lock_version
             )

    refute automatic.reply_cc_edited
  end

  test "foreign sending addresses are rejected and old drafts expire", c do
    channel = insert_inbound_channel(tenant_id: insert_tenant().id)

    assert {:error, :invalid_channel} =
             MessageDrafts.save(c.scope, c.thread.id, %{reply_channel_id: channel.id}, 0)

    assert {:error, :invalid_channel} =
             MessageDrafts.save(c.scope, c.thread.id, %{"reply_channel_id" => channel.id}, 0)

    assert {:ok, saved} = MessageDrafts.save(c.scope, c.thread.id, %{note_text: "Old"}, 0)

    Repo.update!(
      Ecto.Changeset.change(saved,
        updated_at:
          DateTime.add(DateTime.utc_now(), -31 * 86_400, :second) |> DateTime.truncate(:second)
      )
    )

    assert MessageDrafts.sweep_expired() == 1
    assert Repo.aggregate(StaffMessageDraft, :count) == 0
    assert Repo.get(StaffAccount, c.staff.id)
  end
end
