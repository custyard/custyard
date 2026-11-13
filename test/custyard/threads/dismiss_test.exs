defmodule Custyard.Threads.DismissTest do
  # SQLite doesn't support async tests due to database locking
  use Custyard.DataCase, async: false

  import Custyard.Factory

  alias Custyard.{AuditEvent, Message, Scoring, Thread, Threads}
  alias Custyard.Threads.QueuePreview

  setup do
    tenant = insert_tenant()
    Process.put(:factory_tenant_id, tenant.id)
    staff = insert_staff_account(role: "admin", tenant_id: tenant.id)
    org = insert_organization(tenant_id: tenant.id)
    thread = insert_thread(organization_id: org.id, state: :active, subject: "Refund request")
    insert_message(thread_id: thread.id, body: "Where is my refund?")

    {:ok,
     tenant: tenant,
     staff: staff,
     org: org,
     thread: thread,
     scope: Custyard.Scope.for_staff(staff, tenant)}
  end

  defp notes(thread) do
    Repo.all(
      from(m in Message,
        where: m.thread_id == ^thread.id and m.is_internal_note,
        order_by: m.id
      )
    )
  end

  describe "dismiss/2" do
    test "resolves the thread as a staff action", c do
      assert {:ok, %Thread{state: :resolved} = resolved} = Threads.dismiss(c.scope, c.thread.id)
      assert resolved.id == c.thread.id

      stored = Repo.get!(Thread, c.thread.id)
      assert stored.state == :resolved
      assert DateTime.diff(DateTime.utc_now(), stored.last_staff_action_at) in 0..5
    end

    test "leaves an internal note by the staff member, with its audit record", c do
      {:ok, _} = Threads.dismiss(c.scope, c.thread.id)

      assert [note] = notes(c.thread)
      assert note.body == "Dismissed from the queue without a reply."
      assert note.source == :staff
      assert note.is_internal_note
      assert note.author_staff_id == c.staff.id
      # A note is never mail: it has no delivery to attempt.
      assert note.delivery_status == nil

      audit = Repo.get_by!(AuditEvent, event_type: :internal_note_created, thread_id: c.thread.id)
      assert audit.payload["message_db_id"] == note.id
      assert audit.payload["staff_id"] == c.staff.id
    end

    test "the note does not count as a reply to the customer", c do
      {:ok, _} = Threads.dismiss(c.scope, c.thread.id)

      preview = Threads.queue_previews(c.scope, [c.thread.id])[c.thread.id]
      assert %{snippet_from: :note, last_speaker: :customer} = preview
      assert preview.snippet == "Dismissed from the queue without a reply."

      # Reopened, it is the customer who is still waiting.
      {:ok, reopened} = Threads.set_state(c.scope, c.thread.id, :active)
      assert QueuePreview.turn(reopened, preview) == :ours
      assert c.thread.id in Threads.queue_ids(c.scope, filter: "needs_reply")
    end

    test "moves the thread from the queue to the resolved filter", c do
      older = insert_thread(organization_id: c.org.id, state: :resolved)

      Repo.update_all(from(t in Thread, where: t.id == ^older.id),
        set: [updated_at: DateTime.add(DateTime.utc_now(:second), -3600)]
      )

      assert c.thread.id in Threads.queue_ids(c.scope, filter: "needs_reply")

      {:ok, _} = Threads.dismiss(c.scope, c.thread.id)

      for filter <- ~w(needs_reply all active) do
        refute c.thread.id in Threads.queue_ids(c.scope, filter: filter), "filter #{filter}"
      end

      # The latest to be resolved leads the list.
      assert Threads.queue_ids(c.scope, filter: "resolved") == [c.thread.id, older.id]
    end

    test "recalculates the score and broadcasts like Mark resolved", c do
      Repo.update_all(from(t in Thread, where: t.id == ^c.thread.id), set: [cached_score: 9_999])
      Phoenix.PubSub.subscribe(Custyard.PubSub, "threads")
      Phoenix.PubSub.subscribe(Custyard.PubSub, "threads:org:#{c.org.id}")
      id = c.thread.id

      {:ok, _} = Threads.dismiss(c.scope, id)

      assert_receive {:thread_updated, ^id}
      assert_receive {:thread_updated, ^id}

      stored = Repo.get!(Thread, id)
      assert stored.cached_score != 9_999
      assert stored.cached_score == Scoring.calculate(stored)
    end

    test "leaves a resolved thread alone", c do
      {:ok, _} = Threads.dismiss(c.scope, c.thread.id)
      Phoenix.PubSub.subscribe(Custyard.PubSub, "threads")

      assert Threads.dismiss(c.scope, c.thread.id) == {:error, :already_resolved}
      assert [_only_one] = notes(c.thread)
      refute_receive {:thread_updated, _}, 50
    end

    test "is refused to staff who may not change thread state", c do
      agent = staff_scope(c.tenant.id, "agent")
      Phoenix.PubSub.subscribe(Custyard.PubSub, "threads")

      assert Threads.dismiss(agent, c.thread.id) == {:error, :unauthorized}
      assert Repo.get!(Thread, c.thread.id).state == :active
      assert notes(c.thread) == []
      refute_receive {:thread_updated, _}, 50
    end

    test "is refused across tenants", c do
      foreign = staff_scope(insert_tenant().id)

      assert Threads.dismiss(foreign, c.thread.id) == {:error, :unauthorized}
      assert Repo.get!(Thread, c.thread.id).state == :active
      assert notes(c.thread) == []
    end

    test "dismisses a thread without a customer", c do
      thread = insert_thread(tenant_id: c.tenant.id, source: :public_intake, state: :new)
      Phoenix.PubSub.subscribe(Custyard.PubSub, "threads")
      id = thread.id

      assert {:ok, %Thread{state: :resolved}} = Threads.dismiss(c.scope, id)
      assert_receive {:thread_updated, ^id}
      assert [%Message{author_staff_id: staff_id}] = notes(thread)
      assert staff_id == c.staff.id
    end
  end

  describe "set_state/3" do
    test "writes the state and the staff action time, then rescores and broadcasts", c do
      Phoenix.PubSub.subscribe(Custyard.PubSub, "threads")
      Phoenix.PubSub.subscribe(Custyard.PubSub, "threads:org:#{c.org.id}")
      id = c.thread.id

      for state <- [:waiting, :resolved, :active] do
        Repo.update_all(from(t in Thread, where: t.id == ^id),
          set: [cached_score: 9_999, last_staff_action_at: nil]
        )

        assert {:ok, %Thread{state: ^state}} = Threads.set_state(c.scope, id, state)
        assert_receive {:thread_updated, ^id}
        assert_receive {:thread_updated, ^id}

        stored = Repo.get!(Thread, id)
        assert stored.state == state
        assert %DateTime{} = stored.last_staff_action_at
        assert stored.cached_score == Scoring.calculate(stored)
      end

      # A state change leaves no note.
      assert notes(c.thread) == []
    end

    test "is refused to an agent, another tenant and an unknown state", c do
      assert Threads.set_state(staff_scope(c.tenant.id, "agent"), c.thread.id, :resolved) ==
               {:error, :unauthorized}

      assert Threads.set_state(staff_scope(insert_tenant().id), c.thread.id, :resolved) ==
               {:error, :unauthorized}

      assert_raise FunctionClauseError, fn ->
        Threads.set_state(c.scope, c.thread.id, :dormant)
      end

      assert Repo.get!(Thread, c.thread.id).state == :active
    end
  end
end
