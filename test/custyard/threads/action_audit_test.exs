defmodule Custyard.Threads.ActionAuditTest do
  # SQLite doesn't support async tests due to database locking
  use Custyard.DataCase, async: false

  import Custyard.Factory

  alias Custyard.{AuditEvent, Contact, Thread, Threads}

  setup do
    tenant = insert_tenant()
    Process.put(:factory_tenant_id, tenant.id)
    staff = insert_staff_account(role: "admin", tenant_id: tenant.id)
    org = insert_organization(tenant_id: tenant.id)
    contact = insert_contact(organization_id: org.id, email: "digest@sender.example.com")

    thread =
      insert_thread(
        organization_id: org.id,
        contact_id: contact.id,
        state: :active,
        subject: "Refund request"
      )

    {:ok,
     tenant: tenant,
     staff: staff,
     org: org,
     contact: contact,
     thread: thread,
     scope: Custyard.Scope.for_staff(staff, tenant)}
  end

  defp events(type) do
    Repo.all(from(e in AuditEvent, where: e.event_type == ^type, order_by: e.id))
  end

  describe "set_state/3" do
    test "records who changed the state, and from what to what", c do
      {:ok, _} = Threads.set_state(c.scope, c.thread.id, :waiting)
      {:ok, _} = Threads.set_state(c.scope, c.thread.id, :resolved)

      assert [first, second] = events(:thread_state_changed)

      assert first.payload == %{"staff_id" => c.staff.id, "from" => "active", "to" => "waiting"}

      assert second.payload == %{
               "staff_id" => c.staff.id,
               "from" => "waiting",
               "to" => "resolved"
             }

      for event <- [first, second] do
        assert event.source == "staff"
        assert event.tenant_id == c.tenant.id
        assert event.thread_id == c.thread.id
        assert event.organization_id == c.org.id
        assert event.message_id == nil
      end
    end

    test "records nothing when the state stays the same", c do
      assert {:ok, %Thread{state: :active}} = Threads.set_state(c.scope, c.thread.id, :active)
      assert events(:thread_state_changed) == []
    end

    test "records nothing when the change is refused", c do
      assert Threads.set_state(staff_scope(c.tenant.id, "agent"), c.thread.id, :resolved) ==
               {:error, :unauthorized}

      assert Threads.set_state(staff_scope(insert_tenant().id), c.thread.id, :resolved) ==
               {:error, :unauthorized}

      assert events(:thread_state_changed) == []
    end

    test "records the change on a thread without a customer", c do
      thread = insert_thread(tenant_id: c.tenant.id, source: :public_intake, state: :new)

      {:ok, _} = Threads.set_state(c.scope, thread.id, :resolved)

      assert [event] = events(:thread_state_changed)
      assert event.thread_id == thread.id
      assert event.tenant_id == c.tenant.id
      assert event.organization_id == nil
      assert event.payload == %{"staff_id" => c.staff.id, "from" => "new", "to" => "resolved"}
    end
  end

  describe "dismiss/2" do
    test "records the state change next to the note", c do
      {:ok, _} = Threads.dismiss(c.scope, c.thread.id)

      assert [event] = events(:thread_state_changed)
      assert event.thread_id == c.thread.id
      assert event.payload == %{"staff_id" => c.staff.id, "from" => "active", "to" => "resolved"}
      assert [_note] = events(:internal_note_created)
    end

    test "records nothing for a thread that is resolved already", c do
      {:ok, _} = Threads.dismiss(c.scope, c.thread.id)

      assert Threads.dismiss(c.scope, c.thread.id) == {:error, :already_resolved}
      assert [_only_one] = events(:thread_state_changed)
    end
  end

  describe "ignore_sender/2 and unignore_sender/2" do
    test "record who ignored the sender and who stopped", c do
      sibling = insert_thread(organization_id: c.org.id, contact_id: c.contact.id, state: :new)

      {:ok, _} = Threads.ignore_sender(c.scope, c.thread.id)
      {:ok, _} = Threads.unignore_sender(c.scope, sibling.id)

      assert [ignored, stopped] = events(:sender_ignored)

      assert ignored.thread_id == c.thread.id

      assert ignored.payload == %{
               "staff_id" => c.staff.id,
               "contact_id" => c.contact.id,
               "ignored" => true
             }

      # Recorded on the thread the staff member acted from.
      assert stopped.thread_id == sibling.id

      assert stopped.payload == %{
               "staff_id" => c.staff.id,
               "contact_id" => c.contact.id,
               "ignored" => false
             }

      for event <- [ignored, stopped] do
        assert event.source == "staff"
        assert event.tenant_id == c.tenant.id
        assert event.organization_id == c.org.id
      end
    end

    test "record nothing when nothing changes", c do
      {:ok, _} = Threads.unignore_sender(c.scope, c.thread.id)
      assert events(:sender_ignored) == []

      {:ok, _} = Threads.ignore_sender(c.scope, c.thread.id)
      {:ok, _} = Threads.ignore_sender(c.scope, c.thread.id)
      assert [_only_one] = events(:sender_ignored)
    end

    test "record nothing when refused or when the thread has no sender", c do
      agent = staff_scope(c.tenant.id, "agent")
      without_contact = insert_thread(tenant_id: c.tenant.id, source: :public_intake)

      assert Threads.ignore_sender(agent, c.thread.id) == {:error, :unauthorized}
      assert Threads.ignore_sender(c.scope, without_contact.id) == {:error, :no_contact}

      assert events(:sender_ignored) == []
      assert Repo.get!(Contact, c.contact.id).ignored_at == nil
    end

    test "never store the sender's address", c do
      {:ok, _} = Threads.ignore_sender(c.scope, c.thread.id)

      assert [event] = events(:sender_ignored)
      refute inspect(event) =~ "digest@sender.example.com"
    end
  end
end
