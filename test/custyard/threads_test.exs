defmodule Custyard.ThreadsTest do
  # SQLite doesn't support async tests due to database locking
  use Custyard.DataCase, async: false

  alias Custyard.Auth.Token
  alias Custyard.Email.Outbound
  alias Custyard.{Threads, Intake, Message, Prospect, Repo}

  import Custyard.Factory
  import Swoosh.TestAssertions

  setup do
    tenant = insert_tenant()
    Process.put(:factory_tenant_id, tenant.id)
    :ok
  end

  defp scope(staff),
    do: Custyard.Scope.for_staff(staff, Custyard.Tenants.get_tenant!(staff.tenant_id))

  defp current_scope do
    tenant_id = Process.get(:factory_tenant_id)
    key = {:thread_scope, tenant_id}

    case Process.get(key) do
      nil ->
        scope = scope(insert_staff_account(role: "admin", tenant_id: tenant_id))
        Process.put(key, scope)
        scope

      scope ->
        scope
    end
  end

  test "tenant staff can mutate only their workspace's unassigned threads" do
    own = insert_tenant()
    foreign = insert_tenant()
    staff = insert_staff_account(role: "agent", tenant_id: own.id)
    thread = insert_thread(tenant_id: own.id, organization_id: nil, source: :public_intake)

    other =
      insert_thread(tenant_id: foreign.id, organization_id: nil, source: :public_intake)

    assert {:ok, :allowed} =
             Threads.with_access(scope(staff), thread.id, fn _, _ ->
               {:ok, :allowed}
             end)

    assert {:error, :unauthorized} =
             Threads.with_access(scope(staff), other.id, fn _, _ ->
               flunk("foreign thread")
             end)
  end

  test "deleting a customer does not revoke tenant staff membership" do
    org = insert_organization()
    staff = insert_staff_account(role: "agent", tenant_id: org.tenant_id)
    Repo.delete!(org)

    thread =
      insert_thread(tenant_id: org.tenant_id, organization_id: nil, source: :public_intake)

    assert {:ok, :allowed} =
             Threads.with_access(scope(staff), thread.id, fn _, _ ->
               {:ok, :allowed}
             end)
  end

  test "a thread cannot be relinked to another workspace's customer" do
    own = insert_organization()
    foreign = insert_organization(tenant_id: insert_tenant().id)
    thread = insert_thread(tenant_id: own.tenant_id, organization_id: own.id)

    assert_raise Ecto.ConstraintError, fn ->
      thread |> Ecto.Changeset.change(organization_id: foreign.id) |> Repo.update!()
    end
  end

  test "scoped writes use staff's current tenant assignment" do
    own = insert_tenant()
    foreign = insert_tenant()
    staff = insert_staff_account(role: "admin", tenant_id: own.id)
    thread = insert_thread(tenant_id: own.id)
    staff |> Ecto.Changeset.change(tenant_id: foreign.id) |> Repo.update!()

    assert {:error, :unauthorized} =
             Threads.send_reply(thread, "Stale assignment", staff: staff)
  end

  describe "list_neglected" do
    test "returns threads excluding resolved" do
      org = insert_organization()
      active = insert_thread(organization_id: org.id, state: :active)
      _resolved = insert_thread(organization_id: org.id, state: :resolved)

      results = Threads.neglected(current_scope())
      ids = Enum.map(results, & &1.id)

      assert active.id in ids
      refute Enum.any?(results, &(&1.state == :resolved))
    end

    test "excludes snoozed threads" do
      org = insert_organization()
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      _snoozed = insert_thread(organization_id: org.id, snoozed_until: future)
      active = insert_thread(organization_id: org.id, snoozed_until: nil)

      results = Threads.neglected(current_scope())
      ids = Enum.map(results, & &1.id)

      assert active.id in ids
      refute Enum.any?(results, fn c -> c.snoozed_until != nil end)
    end

    test "preloads organization and contact" do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id)
      _conv = insert_thread(organization_id: org.id, contact_id: contact.id)

      [result] = Threads.neglected(current_scope())

      assert result.organization.id == org.id
      assert result.contact.id == contact.id
    end

    test "org scoping includes nil-org threads and excludes other orgs" do
      org = insert_organization()
      other_org = insert_organization()

      own = insert_thread(organization_id: org.id)
      other = insert_thread(organization_id: other_org.id)
      unlinked = insert_thread(organization_id: nil, source: :disambiguation)

      results = Threads.neglected(current_scope(), organization_id: org.id)
      ids = Enum.map(results, & &1.id)

      assert own.id in ids
      assert unlinked.id in ids
      refute other.id in ids
    end
  end

  describe "list_for_attention_queue/1" do
    test "returns threads ordered by cached_score descending" do
      org = insert_organization()

      conv_low = insert_thread(organization_id: org.id, cached_score: 10)
      conv_high = insert_thread(organization_id: org.id, cached_score: 50)
      conv_mid = insert_thread(organization_id: org.id, cached_score: 30)

      results = Threads.list(current_scope())
      ids = Enum.map(results, & &1.thread.id)

      assert ids == [conv_high.id, conv_mid.id, conv_low.id]
    end

    test "excludes snoozed threads" do
      org = insert_organization()
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      _snoozed = insert_thread(organization_id: org.id, snoozed_until: future)
      active = insert_thread(organization_id: org.id, snoozed_until: nil)

      results = Threads.list(current_scope())
      ids = Enum.map(results, & &1.thread.id)

      assert active.id in ids
      refute Enum.any?(results, &(&1.thread.snoozed_until != nil))
    end

    test "filters by state" do
      org = insert_organization()

      new_conv = insert_thread(organization_id: org.id, state: :new)
      active_conv = insert_thread(organization_id: org.id, state: :active)
      _waiting_conv = insert_thread(organization_id: org.id, state: :waiting)

      new_results = Threads.list(current_scope(), filter: "new")
      new_ids = Enum.map(new_results, & &1.thread.id)

      assert new_conv.id in new_ids
      refute active_conv.id in new_ids
    end

    test "includes message count" do
      conv = insert_thread()
      insert_message(thread_id: conv.id)
      insert_message(thread_id: conv.id)

      [result] = Threads.list(current_scope())

      assert result.message_count == 2
    end

    test "org scoping includes nil-org threads and excludes other orgs" do
      org = insert_organization()
      other_org = insert_organization()

      own = insert_thread(organization_id: org.id)
      other = insert_thread(organization_id: other_org.id)
      unlinked = insert_thread(organization_id: nil, source: :disambiguation)

      results = Threads.list(current_scope(), organization_id: org.id)
      ids = Enum.map(results, & &1.thread.id)

      assert own.id in ids
      assert unlinked.id in ids
      refute other.id in ids
    end

    test "unscoped (super_admin) queue includes nil-org threads" do
      org = insert_organization()
      own = insert_thread(organization_id: org.id)
      unlinked = insert_thread(organization_id: nil, source: :disambiguation)

      results = Threads.list(current_scope())
      ids = Enum.map(results, & &1.thread.id)

      assert own.id in ids
      assert unlinked.id in ids
    end
  end

  describe "list_for_organization/2" do
    test "returns threads for the given organization" do
      org1 = insert_organization()
      org2 = insert_organization()

      conv1 = insert_thread(organization_id: org1.id)
      _conv2 = insert_thread(organization_id: org2.id)

      results = Threads.list_for_organization(org1.id)
      ids = Enum.map(results, & &1.id)

      assert ids == [conv1.id]
    end

    test "excludes resolved threads by default" do
      org = insert_organization()

      active = insert_thread(organization_id: org.id, state: :active)
      _resolved = insert_thread(organization_id: org.id, state: :resolved)

      results = Threads.list_for_organization(org.id)
      ids = Enum.map(results, & &1.id)

      assert ids == [active.id]
    end

    test "includes resolved when option set" do
      org = insert_organization()

      active = insert_thread(organization_id: org.id, state: :active)
      resolved = insert_thread(organization_id: org.id, state: :resolved)

      results = Threads.list_for_organization(org.id, include_resolved: true)
      ids = Enum.map(results, & &1.id)

      assert active.id in ids
      assert resolved.id in ids
    end

    test "filters by contact_id" do
      org = insert_organization()
      contact1 = insert_contact(organization_id: org.id)
      contact2 = insert_contact(organization_id: org.id)

      conv1 = insert_thread(organization_id: org.id, contact_id: contact1.id)
      _conv2 = insert_thread(organization_id: org.id, contact_id: contact2.id)

      results = Threads.list_for_organization(org.id, contact_id: contact1.id)
      ids = Enum.map(results, & &1.id)

      assert ids == [conv1.id]
    end
  end

  describe "get_thread/1" do
    test "returns thread when found" do
      conv = insert_thread()

      result = Threads.get(current_scope(), conv.id)

      assert result.id == conv.id
    end

    test "returns nil when not found" do
      assert Threads.get(current_scope(), 99_999) == nil
    end
  end

  describe "get_thread!/1" do
    test "returns thread when found" do
      conv = insert_thread()

      result = Threads.get!(current_scope(), conv.id)

      assert result.id == conv.id
    end

    test "raises when not found" do
      assert_raise Ecto.NoResultsError, fn ->
        Threads.get!(current_scope(), 99_999)
      end
    end
  end

  describe "get_thread_for_organization/2" do
    test "returns thread when org matches" do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)

      assert {:ok, result} = Threads.get_thread_for_organization(conv.id, org.id)
      assert result.id == conv.id
    end

    test "returns error when thread not found" do
      assert {:error, :not_found} = Threads.get_thread_for_organization(99_999, 1)
    end

    test "returns error when org does not match" do
      org1 = insert_organization()
      org2 = insert_organization()
      conv = insert_thread(organization_id: org1.id)

      assert {:error, :unauthorized} =
               Threads.get_thread_for_organization(conv.id, org2.id)
    end
  end

  describe "get_with_messages/1" do
    test "preloads messages in order" do
      conv = insert_thread()
      msg1 = insert_message(thread_id: conv.id)
      msg2 = insert_message(thread_id: conv.id)

      result = Threads.get_with_messages(current_scope(), conv.id)

      assert length(result.messages) == 2
      assert [first, second] = result.messages
      assert first.id == msg1.id
      assert second.id == msg2.id
    end

    test "preloads organization and contact" do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id)
      conv = insert_thread(organization_id: org.id, contact_id: contact.id)

      result = Threads.get_with_messages(current_scope(), conv.id)

      assert result.organization.id == org.id
      assert result.contact.id == contact.id
    end
  end

  describe "list_public_messages/1" do
    test "returns non-internal messages" do
      conv = insert_thread()
      public = insert_message(thread_id: conv.id, is_internal_note: false)
      _internal = insert_message(thread_id: conv.id, is_internal_note: true)

      results = Threads.list_public_messages(conv.id)
      ids = Enum.map(results, & &1.id)

      assert ids == [public.id]
    end

    test "orders messages by inserted_at ascending" do
      conv = insert_thread()
      first = insert_message(thread_id: conv.id, is_internal_note: false)
      second = insert_message(thread_id: conv.id, is_internal_note: false)

      results = Threads.list_public_messages(conv.id)
      ids = Enum.map(results, & &1.id)

      assert ids == [first.id, second.id]
    end
  end

  describe "count_messages/1" do
    test "returns count of messages" do
      conv = insert_thread()
      insert_message(thread_id: conv.id)
      insert_message(thread_id: conv.id)
      insert_message(thread_id: conv.id)

      assert Threads.count_messages(conv.id) == 3
    end

    test "returns 0 for thread with no messages" do
      conv = insert_thread()

      assert Threads.count_messages(conv.id) == 0
    end
  end

  describe "create_thread/1" do
    test "creates a thread with valid attributes" do
      org = insert_organization()

      assert {:ok, conv} =
               Threads.create(current_scope(), %{
                 subject: "Test subject",
                 organization_id: org.id
               })

      assert conv.subject == "Test subject"
      assert conv.organization_id == org.id
      assert conv.state == :new
    end

    test "returns error for invalid attributes" do
      assert {:error, changeset} = Threads.create(current_scope(), %{})
      assert %{subject: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "create_message/1" do
    test "creates a message" do
      conv = insert_thread()

      assert {:ok, message} =
               Threads.create_message(%{
                 thread_id: conv.id,
                 source: :email,
                 body: "Test message",
                 is_internal_note: false
               })

      assert message.body == "Test message"
      assert message.thread_id == conv.id
    end
  end

  describe "create_message!/1" do
    test "creates a message and returns it" do
      conv = insert_thread()

      message =
        Threads.create_message!(%{
          thread_id: conv.id,
          source: :portal,
          body: "Test message",
          is_internal_note: false
        })

      assert message.body == "Test message"
      assert message.source == :portal
    end

    test "raises on invalid attributes" do
      conv = insert_thread()

      assert_raise Ecto.InvalidChangesetError, fn ->
        Threads.create_message!(%{
          thread_id: conv.id,
          source: :email
          # missing body
        })
      end
    end
  end

  describe "soft_delete_message/2" do
    test "stamps deleted_at and the deleting staff, keeping the original body" do
      conv = insert_thread()
      message = insert_message(thread_id: conv.id, body: "Sensitive content")
      staff = insert_staff_account()

      assert {:ok, deleted} = Threads.soft_delete_message(message, staff)

      assert %DateTime{} = deleted.deleted_at
      assert deleted.deleted_by_staff_id == staff.id

      # Soft delete only: the row and its original body stay in the database.
      reloaded = Repo.get!(Custyard.Message, message.id)
      assert reloaded.body == "Sensitive content"
      assert %DateTime{} = reloaded.deleted_at
    end

    test "broadcasts message_updated on the thread topic" do
      conv = insert_thread()
      message = insert_message(thread_id: conv.id)
      staff = insert_staff_account()

      Phoenix.PubSub.subscribe(Custyard.PubSub, "thread:#{conv.id}")

      assert {:ok, _deleted} = Threads.soft_delete_message(message, staff)

      conv_id = conv.id
      assert_received {:message_updated, ^conv_id}
    end

    test "is idempotent and preserves the original deletion attribution" do
      conv = insert_thread()
      message = insert_message(thread_id: conv.id)
      first_staff = insert_staff_account()
      second_staff = insert_staff_account()

      {:ok, deleted} = Threads.soft_delete_message(message, first_staff)
      assert {:ok, unchanged} = Threads.soft_delete_message(deleted, second_staff)

      assert unchanged.deleted_at == deleted.deleted_at
      assert unchanged.deleted_by_staff_id == first_staff.id

      reloaded = Repo.get!(Custyard.Message, message.id)
      assert reloaded.deleted_by_staff_id == first_staff.id
    end
  end

  describe "update_state/2" do
    test "updates thread state" do
      conv = insert_thread(state: :new)

      assert {:ok, updated} = Threads.update_state(conv, :active)
      assert updated.state == :active
    end

    test "allows valid state transitions" do
      # :new -> :active
      conv = insert_thread(state: :new)
      assert {:ok, _} = Threads.update_state(conv, :active)

      # :active -> :waiting
      conv = insert_thread(state: :active)
      assert {:ok, _} = Threads.update_state(conv, :waiting)

      # :waiting -> :dormant
      conv = insert_thread(state: :waiting)
      assert {:ok, _} = Threads.update_state(conv, :dormant)

      # :dormant -> :active (reactivate)
      conv = insert_thread(state: :dormant)
      assert {:ok, _} = Threads.update_state(conv, :active)

      # :active -> :resolved
      conv = insert_thread(state: :active)
      assert {:ok, _} = Threads.update_state(conv, :resolved)

      # :resolved -> :active (reopen)
      conv = insert_thread(state: :resolved)
      assert {:ok, _} = Threads.update_state(conv, :active)
    end

    test "prevents invalid state transitions" do
      # :new cannot go directly to :dormant
      conv = insert_thread(state: :new)
      assert {:error, changeset} = Threads.update_state(conv, :dormant)
      assert %{state: [error_msg]} = errors_on(changeset)
      assert error_msg =~ "cannot transition from new to dormant"

      # :new cannot go to :waiting
      conv = insert_thread(state: :new)
      assert {:error, changeset} = Threads.update_state(conv, :waiting)
      assert %{state: [_]} = errors_on(changeset)

      # :resolved cannot go to :waiting
      conv = insert_thread(state: :resolved)
      assert {:error, changeset} = Threads.update_state(conv, :waiting)
      assert %{state: [_]} = errors_on(changeset)

      # :dormant cannot go to :waiting
      conv = insert_thread(state: :dormant)
      assert {:error, changeset} = Threads.update_state(conv, :waiting)
      assert %{state: [_]} = errors_on(changeset)
    end

    test "allows same state (no-op)" do
      conv = insert_thread(state: :active)
      assert {:ok, updated} = Threads.update_state(conv, :active)
      assert updated.state == :active
    end
  end

  describe "snooze/2" do
    test "sets snoozed_until timestamp" do
      conv = insert_thread()
      until = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)

      assert {:ok, snoozed} = Threads.snooze(conv, until)
      assert snoozed.snoozed_until == until
    end
  end

  describe "update_thread/2" do
    test "updates thread with valid attributes" do
      conv = insert_thread()

      assert {:ok, updated} =
               Threads.update_thread(conv, %{subject: "Updated subject"})

      assert updated.subject == "Updated subject"
    end

    test "ignores cached_score in attrs (computed field)" do
      conv = insert_thread(cached_score: 10)

      # cached_score should not be updatable via changeset
      assert {:ok, updated} =
               Threads.update_thread(conv, %{cached_score: 9999, subject: "Test"})

      # Score unchanged (input ignored)
      assert updated.cached_score == 10
      # But valid attrs still applied
      assert updated.subject == "Test"
    end

    test "updates last_staff_action_at" do
      conv = insert_thread()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:ok, updated} =
               Threads.update_thread(conv, %{last_staff_action_at: now})

      assert updated.last_staff_action_at == now
    end
  end

  describe "reload!/1" do
    test "reloads thread from database" do
      conv = insert_thread(cached_score: 10)

      # Update the score directly in the database
      Custyard.Repo.update!(Ecto.Changeset.change(conv, cached_score: 99))

      # Original struct still has old value
      assert conv.cached_score == 10

      # Reloaded struct has new value
      reloaded = Threads.reload!(conv)
      assert reloaded.cached_score == 99
    end
  end

  describe "task functions" do
    test "create_task/1 creates a task" do
      conv = insert_thread()

      assert {:ok, task} =
               Threads.create_task(%{title: "Fix bug", thread_id: conv.id})

      assert task.title == "Fix bug"
      assert task.state == :open
    end

    test "get_task!/1 retrieves a task" do
      conv = insert_thread()
      {:ok, task} = Threads.create_task(%{title: "Test", thread_id: conv.id})

      result = Threads.get_task!(task.id)
      assert result.id == task.id
    end

    test "update_task_state/2 changes task state" do
      conv = insert_thread()
      {:ok, task} = Threads.create_task(%{title: "Test", thread_id: conv.id})

      assert {:ok, updated} = Threads.update_task_state(task, :in_progress)
      assert updated.state == :in_progress
    end

    test "update_task/2 updates task attributes" do
      conv = insert_thread()
      {:ok, task} = Threads.create_task(%{title: "Test", thread_id: conv.id})

      assert {:ok, updated} =
               Threads.update_task(task, %{title: "Updated", portal_visible: false})

      assert updated.title == "Updated"
      assert updated.portal_visible == false
    end

    test "delete_task/1 removes a task" do
      conv = insert_thread()
      {:ok, task} = Threads.create_task(%{title: "Test", thread_id: conv.id})

      assert {:ok, _} = Threads.delete_task(task)
      assert_raise Ecto.NoResultsError, fn -> Threads.get_task!(task.id) end
    end
  end

  describe "list_portal_visible_tasks/1" do
    test "returns only portal-visible tasks" do
      conv = insert_thread()

      {:ok, visible} =
        Threads.create_task(%{
          title: "Visible",
          thread_id: conv.id,
          portal_visible: true
        })

      {:ok, _hidden} =
        Threads.create_task(%{
          title: "Hidden",
          thread_id: conv.id,
          portal_visible: false
        })

      results = Threads.list_portal_visible_tasks(conv.id)
      ids = Enum.map(results, & &1.id)

      assert ids == [visible.id]
    end

    test "orders tasks by inserted_at" do
      conv = insert_thread()

      {:ok, first} =
        Threads.create_task(%{
          title: "First",
          thread_id: conv.id,
          portal_visible: true
        })

      {:ok, second} =
        Threads.create_task(%{
          title: "Second",
          thread_id: conv.id,
          portal_visible: true
        })

      results = Threads.list_portal_visible_tasks(conv.id)
      ids = Enum.map(results, & &1.id)

      assert ids == [first.id, second.id]
    end
  end

  describe "default_reply_cc/2" do
    setup do
      org = insert_organization(name: "CC Corp")
      contact = insert_contact(organization_id: org.id, email: "alice@customer.example")
      route = insert_inbound_route(organization_id: org.id, source: :lettermint)

      channel =
        insert_inbound_channel(
          inbound_route_id: route.id,
          public_address: "help@acme.example",
          state: :active
        )

      conv =
        insert_thread(
          organization_id: org.id,
          contact_id: contact.id,
          inbound_channel_id: channel.id
        )

      %{conv: conv, channel: channel}
    end

    test "returns the latest customer message's To and CC minus our side", %{
      conv: conv,
      channel: channel
    } do
      insert_message(
        thread_id: conv.id,
        source: :email,
        sender_email: "Alice <alice@customer.example>",
        reply_to: "alice-alt@customer.example",
        to_addresses: ["help@acme.example", Custyard.InboundChannels.ingress_address(channel)],
        cc_addresses: ["Boss@customer.example", "alice-alt@customer.example", "me@acme.example"],
        triage_class: :customer
      )

      assert Threads.default_reply_cc(conv, staff_email: "me@acme.example") ==
               ["boss@customer.example"]
    end

    test "ignores auto-responses and suspect messages", %{conv: conv} do
      insert_message(
        thread_id: conv.id,
        source: :email,
        sender_email: "alice@customer.example",
        cc_addresses: ["real@customer.example"],
        triage_class: :customer
      )

      insert_message(
        thread_id: conv.id,
        source: :email,
        sender_email: "noreply@spammer.example",
        cc_addresses: ["victim@elsewhere.example"],
        triage_class: :auto_response
      )

      assert Threads.default_reply_cc(conv) == ["real@customer.example"]
    end

    test "is empty without an email message, and always for prospects" do
      org = insert_organization()
      assert Threads.default_reply_cc(insert_thread(organization_id: org.id)) == []

      prospect_conv = insert_thread(organization_id: org.id, source: :public_intake)

      insert_message(
        thread_id: prospect_conv.id,
        source: :email,
        cc_addresses: ["x@example.com"]
      )

      assert Threads.default_reply_cc(prospect_conv) == []
    end
  end

  describe "send_reply/3" do
    setup do
      org = insert_organization(name: "Reply Corp")
      contact = insert_contact(organization_id: org.id, email: "customer@example.com")

      thread =
        insert_thread(
          organization_id: org.id,
          contact_id: contact.id,
          subject: "Need help",
          state: :waiting
        )

      # Add a customer message to thread against
      _customer_msg =
        insert_message(
          thread_id: thread.id,
          source: :email,
          sender_email: "customer@example.com",
          message_id: "<inbound-123@customer.com>",
          body: "Please help me"
        )

      {:ok, org: org, contact: contact, thread: thread}
    end

    test "stores a normalised CC list on the reply", %{thread: conv} do
      {:ok, message} =
        Threads.send_reply(conv, "Looping in",
          cc: " Boss@Example.com, boss@example.com;ops@example.com "
        )

      assert message.cc_addresses == ["boss@example.com", "ops@example.com"]
    end

    test "public intake cannot accept CC recipients even through the context", %{
      thread: conv
    } do
      conv |> Ecto.Changeset.change(source: :public_intake) |> Repo.update!()
      # Pass the old snapshot to exercise the transaction's current-source gate.
      assert {:ok, reply} =
               Threads.send_reply(conv, "Private reply", cc: ["other@example.com"])

      assert reply.cc_addresses == []
    end

    test "rejects an invalid CC address before writing anything", %{thread: conv} do
      before = Repo.aggregate(Message, :count)

      assert {:error, {:invalid_cc, ["nope"]}} =
               Threads.send_reply(conv, "Looping in", cc: ["ok@example.com", "nope"])

      assert Repo.aggregate(Message, :count) == before
    end

    test "rejects more than 20 CC addresses", %{thread: conv} do
      cc = for n <- 1..21, do: "p#{n}@example.com"
      assert {:error, {:invalid_cc, :too_many}} = Threads.send_reply(conv, "Hi", cc: cc)
    end

    test "creates a message with correct attributes", %{thread: conv} do
      {:ok, message} = Threads.send_reply(conv, "Here is your answer")

      assert message.source == :staff
      assert message.body == "Here is your answer"
      assert message.is_internal_note == false
      assert message.thread_id == conv.id
      assert message.delivery_status == :pending
    end

    test "sets in_reply_to from last customer message", %{thread: conv} do
      {:ok, message} = Threads.send_reply(conv, "Following up")

      assert message.in_reply_to == "<inbound-123@customer.com>"
    end

    test "threads in_reply_to to the latest customer message when messages were preloaded ascending",
         %{thread: conv} do
      # Backdate the setup message so the newer one wins on inserted_at
      backdated =
        DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(m in Custyard.Message, where: m.thread_id == ^conv.id),
        set: [inserted_at: backdated]
      )

      insert_message(
        thread_id: conv.id,
        source: :email,
        message_id: "<inbound-456@customer.com>",
        body: "Any update?"
      )

      # get_with_messages/1 preloads messages ascending — the same shape the
      # LiveView passes in. Regression: the already-loaded association must
      # not decide which message gets threaded.
      preloaded = Threads.get_with_messages(current_scope(), conv.id)

      {:ok, message} = Threads.send_reply(preloaded, "Reply to the follow-up")

      assert message.in_reply_to == "<inbound-456@customer.com>"
    end

    test "breaks inserted_at ties for in_reply_to by message id", %{thread: conv} do
      # Inserted within the same second as the setup message
      insert_message(
        thread_id: conv.id,
        source: :email,
        message_id: "<inbound-tie@customer.com>",
        body: "Second message, same second"
      )

      {:ok, message} = Threads.send_reply(conv, "Tiebreak reply")

      assert message.in_reply_to == "<inbound-tie@customer.com>"
    end

    test "generates a unique outbound message_id", %{thread: conv} do
      {:ok, message} = Threads.send_reply(conv, "Reply one")

      assert message.message_id != nil
      assert String.starts_with?(message.message_id, "<")
      assert String.ends_with?(message.message_id, ">")
      assert message.message_id =~ ~r/c#{conv.id}@/
    end

    test "transitions thread state to :active", %{thread: conv} do
      assert conv.state == :waiting

      {:ok, _message} = Threads.send_reply(conv, "On it")

      reloaded = Repo.get!(Custyard.Thread, conv.id)
      assert reloaded.state == :active
    end

    test "updates last_staff_action_at", %{thread: conv} do
      assert conv.last_staff_action_at == nil

      {:ok, _message} = Threads.send_reply(conv, "Done")

      reloaded = Repo.get!(Custyard.Thread, conv.id)
      assert reloaded.last_staff_action_at != nil
    end

    test "does not use staff personal email when tenant sending is unconfigured", %{
      thread: conv
    } do
      {:ok, message} = Threads.send_reply(conv, "Reply", staff_email: "agent@corp.com")

      assert is_nil(message.sender_email)
    end

    test "route infrastructure does not select a sending identity", %{
      thread: conv,
      org: org
    } do
      # Create a route with a from_address for this org
      insert_inbound_route(
        organization_id: org.id,
        route_type: :general,
        from_address: "support@acme.com"
      )

      {:ok, message} =
        Threads.send_reply(conv, "Reply", staff_email: "agent@corp.com")

      assert is_nil(message.sender_email)
    end

    test "a project does not select tenant sending identity", %{
      org: org,
      contact: contact
    } do
      project = insert_project(organization_id: org.id)

      thread =
        insert_thread(
          organization_id: org.id,
          contact_id: contact.id,
          project_id: project.id,
          subject: "Project thread"
        )

      insert_inbound_route(
        organization_id: org.id,
        route_type: :general,
        from_address: "support@acme.com"
      )

      insert_inbound_route(
        organization_id: org.id,
        route_type: :project,
        project_id: project.id,
        from_address: "projects@acme.com"
      )

      {:ok, message} = Threads.send_reply(thread, "Project reply")

      assert is_nil(message.sender_email)
    end

    test "provider routes do not provide a global sending fallback", %{
      org: org,
      contact: contact
    } do
      project = insert_project(organization_id: org.id)

      thread =
        insert_thread(
          organization_id: org.id,
          contact_id: contact.id,
          project_id: project.id,
          subject: "Project thread"
        )

      insert_inbound_route(
        organization_id: org.id,
        route_type: :general,
        from_address: "support@acme.com"
      )

      insert_inbound_route(
        organization_id: org.id,
        route_type: :project,
        project_id: project.id
      )

      {:ok, message} = Threads.send_reply(thread, "Project reply")

      assert is_nil(message.sender_email)
    end

    test "returns error on empty body", %{thread: conv} do
      # Empty body should fail validation since body is required
      result = Threads.send_reply(conv, "")

      assert {:error, _reason} = result
    end

    test "sets origin to :email for email-sourced thread", %{thread: conv} do
      # Default thread source is :email
      {:ok, message} = Threads.send_reply(conv, "Reply to email thread")

      assert message.origin == :email
    end

    test "sets origin to :lettermint for lettermint-sourced thread" do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, email: "lm-customer@example.com")

      thread =
        insert_thread(
          organization_id: org.id,
          contact_id: contact.id,
          subject: "Lettermint thread",
          source: :lettermint
        )

      insert_message(
        thread_id: thread.id,
        source: :email,
        message_id: "<lm-msg@lettermint.test>",
        body: "Hello from lettermint"
      )

      {:ok, message} = Threads.send_reply(thread, "Lettermint reply")

      assert message.origin == :lettermint
    end

    test "sets origin to :portal for portal-sourced thread" do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, email: "portal-user@example.com")

      thread =
        insert_thread(
          organization_id: org.id,
          contact_id: contact.id,
          subject: "Portal thread",
          source: :portal
        )

      insert_message(
        thread_id: thread.id,
        source: :portal,
        body: "Portal message"
      )

      {:ok, message} = Threads.send_reply(thread, "Portal reply")

      assert message.origin == :portal
    end

    test "defaults origin to :email for disambiguation-sourced thread" do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, email: "ambig@example.com")

      thread =
        insert_thread(
          organization_id: org.id,
          contact_id: contact.id,
          subject: "Disambiguation thread",
          source: :disambiguation
        )

      insert_message(
        thread_id: thread.id,
        source: :email,
        body: "Disambiguated message"
      )

      {:ok, message} = Threads.send_reply(thread, "Disambiguation reply")

      assert message.origin == :email
    end

    test "broadcasts PubSub events on success", %{thread: conv} do
      conv_id = conv.id

      Phoenix.PubSub.subscribe(Custyard.PubSub, "thread:#{conv_id}")
      Phoenix.PubSub.subscribe(Custyard.PubSub, "threads")
      Phoenix.PubSub.subscribe(Custyard.PubSub, "threads:org:#{conv.organization_id}")

      {:ok, _message} = Threads.send_reply(conv, "Broadcast test")

      assert_received {:message_added, ^conv_id}
      assert_received {:thread_updated, ^conv_id}
      assert_received {:thread_updated, ^conv_id}
    end

    test "sender_email is nil when no route and no staff_email", %{thread: conv} do
      {:ok, message} = Threads.send_reply(conv, "No sender")

      assert is_nil(message.sender_email)
    end

    test "message and thread update are atomic", %{thread: conv} do
      # Verify both the message insert and thread update happen together
      before_count =
        Repo.one(
          from m in Custyard.Message,
            where: m.thread_id == ^conv.id and m.source == :staff,
            select: count()
        )

      {:ok, message} = Threads.send_reply(conv, "Atomic test")

      after_count =
        Repo.one(
          from m in Custyard.Message,
            where: m.thread_id == ^conv.id and m.source == :staff,
            select: count()
        )

      # Exactly one staff message was created
      assert after_count == before_count + 1

      # Both the message and thread update succeeded
      reloaded_conv = Repo.get!(Custyard.Thread, conv.id)
      assert reloaded_conv.state == :active
      assert reloaded_conv.last_staff_action_at != nil
      assert message.thread_id == conv.id
    end

    test "reply on a nil-org thread broadcasts on the global topic" do
      thread =
        insert_thread(
          organization_id: nil,
          source: :disambiguation,
          subject: "Unlinked reply thread"
        )

      conv_id = thread.id

      Phoenix.PubSub.subscribe(Custyard.PubSub, "thread:#{conv_id}")
      Phoenix.PubSub.subscribe(Custyard.PubSub, "threads")

      {:ok, message} = Threads.send_reply(thread, "Reply to unlinked prospect")

      assert message.source == :staff
      assert_received {:message_added, ^conv_id}
      assert_received {:thread_updated, ^conv_id}
    end

    test "reply on a nil-org thread never broadcasts to the malformed bare org topic" do
      thread =
        insert_thread(
          organization_id: nil,
          source: :disambiguation,
          subject: "Unlinked reply thread"
        )

      # Subscribing only to the malformed topic a nil org would interpolate
      # into isolates this assertion from the legitimate "threads" topic.
      Phoenix.PubSub.subscribe(Custyard.PubSub, "threads:org:")

      {:ok, _message} = Threads.send_reply(thread, "Reply to unlinked prospect")

      refute_received {:thread_updated, _id}
    end
  end

  describe "broadcast_to_org/2" do
    test "publishes to the org-scoped topic for a real organization id" do
      Phoenix.PubSub.subscribe(Custyard.PubSub, "threads:org:123")

      assert :ok = Threads.broadcast_to_org(123, {:thread_updated, 7})

      assert_received {:thread_updated, 7}
    end

    test "skips the broadcast entirely when organization_id is nil" do
      Phoenix.PubSub.subscribe(Custyard.PubSub, "threads:org:")

      assert :ok = Threads.broadcast_to_org(nil, {:thread_updated, 7})

      refute_received {:thread_updated, 7}
    end
  end

  describe "reply_channel/1" do
    test "prefers the linked contact's email" do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, email: "customer@example.com")
      conv = insert_thread(organization_id: org.id, contact_id: contact.id)

      assert Threads.reply_channel(conv) == {:contact, "customer@example.com"}
    end

    test "contact email wins over a captured prospect email" do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, email: "customer@example.com")

      conv =
        insert_thread(
          source: :public_intake,
          organization_id: contact.organization_id,
          contact_id: contact.id
        )

      insert_prospect(thread_id: conv.id, email: "prospect@example.com")

      assert Threads.reply_channel(conv) == {:contact, "customer@example.com"}
    end

    test "falls back to a captured, non-revoked prospect email" do
      conv = insert_thread(source: :public_intake)
      insert_prospect(thread_id: conv.id, email: "prospect@example.com")

      assert Threads.reply_channel(conv) == {:prospect, "prospect@example.com"}
    end

    test "returns :none when the prospect email is revoked" do
      conv = insert_thread(source: :public_intake)

      insert_prospect(
        thread_id: conv.id,
        email: "prospect@example.com",
        revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

      assert Threads.reply_channel(conv) == :none
    end

    test "returns :none when the prospect has no email" do
      conv = insert_thread(source: :public_intake)
      insert_prospect(thread_id: conv.id)

      assert Threads.reply_channel(conv) == :none
    end

    test "returns :none with neither contact nor prospect" do
      conv = insert_thread(source: :public_intake)

      assert Threads.reply_channel(conv) == :none
    end

    test "list_for_attention_queue/1 preloads the prospect for reply_channel" do
      conv = insert_thread(source: :public_intake, state: :new)
      insert_prospect(thread_id: conv.id, email: "prospect@example.com")

      [%{thread: loaded}] = Threads.list(current_scope())

      assert Ecto.assoc_loaded?(loaded.prospect)
      assert Ecto.assoc_loaded?(loaded.contact)
      assert Threads.reply_channel(loaded) == {:prospect, "prospect@example.com"}
    end
  end

  describe "send_reply/3 consent gate (public intake)" do
    setup do
      tenant = insert_tenant()
      Process.put(:factory_tenant_id, tenant.id)
      configure_tenant_email(tenant.id)
      :ok
    end

    test "prospect with opt-in: reply is pending and delivers to the prospect email" do
      {thread, _prospect} =
        intake_fixture(email: "prospect@example.com", notify_on_reply: true)

      {:ok, message} = Threads.send_reply(thread, "Happy to help")
      assert message.delivery_status == :pending

      # Async delivery is disabled in test config; exercise delivery directly.
      {:ok, delivered} = Outbound.deliver(message)
      assert delivered.delivery_status == :sent

      assert_email_sent(fn email ->
        assert email.to == [{"", "prospect@example.com"}]
      end)
    end

    test "prospect without opt-in: reply is withheld and delivery is skipped" do
      {thread, _prospect} =
        intake_fixture(email: "prospect@example.com", notify_on_reply: false)

      {:ok, message} = Threads.send_reply(thread, "Saved but not emailed")

      assert message.delivery_status == :withheld
      assert Repo.get!(Custyard.Message, message.id).delivery_status == :withheld
      assert_no_email_sent()
    end

    test "no captured email at all: reply is withheld" do
      {thread, _prospect} = intake_fixture([])

      {:ok, message} = Threads.send_reply(thread, "No recipient anywhere")

      assert message.delivery_status == :withheld
      assert_no_email_sent()
    end

    test "revoked prospect has no reply channel: reply is withheld" do
      revoked_at = DateTime.utc_now() |> DateTime.truncate(:second)

      {thread, _prospect} =
        intake_fixture(
          email: "prospect@example.com",
          notify_on_reply: true,
          revoked_at: revoked_at
        )

      {:ok, message} = Threads.send_reply(thread, "Revoked prospect")

      assert message.delivery_status == :withheld
      assert_no_email_sent()
    end

    test "non-intake thread with no recipient keeps the visible failure path" do
      org = insert_organization()
      thread = insert_thread(organization_id: org.id, contact_id: nil)

      {:ok, message} = Threads.send_reply(thread, "No recipient anywhere")

      # :withheld is reserved for the public-intake consent gate — a
      # non-intake no-recipient reply stays :pending and delivery records
      # the failure visibly.
      assert message.delivery_status == :pending

      assert {:error, :no_recipient_email, failed} = Outbound.deliver(message)
      assert failed.delivery_status == :failed
      assert_no_email_sent()
    end

    test "contact channel delivers unconditionally even when the prospect has not opted in" do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, email: "matched@example.com")

      thread =
        insert_thread(
          source: :public_intake,
          organization_id: org.id,
          contact_id: contact.id,
          subject: "Matched an existing contact at capture"
        )

      insert_prospect(
        thread_id: thread.id,
        email: "prospect@example.com",
        notify_on_reply: false
      )

      {:ok, message} = Threads.send_reply(thread, "Established customer path")
      assert message.delivery_status == :pending

      {:ok, delivered} = Outbound.deliver(message)
      assert delivered.delivery_status == :sent

      assert_email_sent(fn email ->
        assert email.to == [{"", "matched@example.com"}]
      end)
    end

    test "public-intake replies never carry the staff's personal address" do
      {thread, _prospect} =
        intake_fixture(email: "prospect@example.com", notify_on_reply: true)

      {:ok, message} =
        Threads.send_reply(thread, "Reply", staff_email: "staff-personal@example.com")

      assert message.sender_email == "support@custyard.local"
    end

    test "public intake retains tenant support sender after linking to a customer" do
      org = insert_organization()

      insert_inbound_route(
        organization_id: org.id,
        route_type: :general,
        from_address: "support@acme.com"
      )

      thread =
        insert_thread(
          source: :public_intake,
          organization_id: org.id,
          subject: "Linked intake thread"
        )

      insert_prospect(
        thread_id: thread.id,
        email: "prospect@example.com",
        notify_on_reply: true
      )

      {:ok, message} =
        Threads.send_reply(thread, "Reply", staff_email: "staff-personal@example.com")

      # Source-keyed rule: neither the org route address nor the staff's
      # personal address — nil selects Outbound's platform fallback.
      assert message.sender_email == "support@custyard.local"
    end

    test "sets origin to :email for public-intake threads" do
      {thread, _prospect} =
        intake_fixture(email: "prospect@example.com", notify_on_reply: true)

      {:ok, message} = Threads.send_reply(thread, "Origin check")

      assert message.origin == :email
    end

    test "toggling notify_on_reply between replies flips delivery" do
      {thread, prospect} =
        intake_fixture(email: "prospect@example.com", notify_on_reply: false)

      {:ok, first} = Threads.send_reply(fresh(thread), "First reply")
      assert first.delivery_status == :withheld

      {:ok, _} = prospect |> Prospect.notification_changeset(true) |> Repo.update()

      {:ok, second} = Threads.send_reply(fresh(thread), "Second reply")
      assert second.delivery_status == :pending

      {:ok, delivered} = Outbound.deliver(second)
      assert delivered.delivery_status == :sent

      assert_email_sent(fn email ->
        assert email.to == [{"", "prospect@example.com"}]
      end)

      {:ok, _} =
        Repo.get!(Prospect, prospect.id)
        |> Prospect.notification_changeset(false)
        |> Repo.update()

      {:ok, third} = Threads.send_reply(fresh(thread), "Third reply")
      assert third.delivery_status == :withheld
    end
  end

  describe "cleanup_resolved_threads/2" do
    test "purges dependent rows while preserving tenant audit and optional project links" do
      org = insert_organization()
      thread = insert_thread(organization_id: org.id, state: :resolved)
      message = insert_message(thread_id: thread.id)
      insert_prospect(thread_id: thread.id)
      project = insert_project(organization_id: org.id, thread_id: thread.id)
      task = insert_task(organization_id: org.id, thread_id: thread.id)
      event = insert_audit_event(thread_id: thread.id, organization_id: org.id)
      backdate_updated_at(thread, 91)
      assert Threads.cleanup_resolved_threads(90) == 1
      refute Repo.get(Message, message.id)
      refute Repo.get_by(Prospect, thread_id: thread.id)
      assert Repo.reload!(project).thread_id == nil
      assert Repo.reload!(task).thread_id == nil
      assert Repo.reload!(event).tenant_id == org.tenant_id
      assert Repo.reload!(event).thread_id == nil
    end

    test "purges resolved non-intake threads after 90 days and keeps younger ones" do
      org = insert_organization()
      old = insert_thread(organization_id: org.id, state: :resolved)
      young = insert_thread(organization_id: org.id, state: :resolved)
      backdate_updated_at(old, 91)
      backdate_updated_at(young, 89)

      assert Threads.cleanup_resolved_threads(90) == 1
      assert Repo.get(Custyard.Thread, old.id) == nil
      assert Repo.get(Custyard.Thread, young.id)
    end

    test "purges a resolved thread that has audit events and keeps its trail" do
      org = insert_organization()
      old = insert_thread(organization_id: org.id, state: :resolved)
      backdate_updated_at(old, 91)
      event = insert_audit_event(thread_id: old.id, organization_id: org.id)

      assert Threads.cleanup_resolved_threads(90) == 1
      assert Repo.get(Custyard.Thread, old.id) == nil

      kept = Repo.get!(Custyard.AuditEvent, event.id)
      assert kept.thread_id == nil
      assert kept.organization_id == org.id
    end

    test "keeps resolved public-intake threads well past the 90-day bound" do
      thread = insert_thread(source: :public_intake, state: :resolved)
      backdate_updated_at(thread, 364)

      assert Threads.cleanup_resolved_threads(90) == 0
      assert Repo.get(Custyard.Thread, thread.id)
    end

    test "purges resolved public-intake threads after 365 days" do
      thread = insert_thread(source: :public_intake, state: :resolved)
      backdate_updated_at(thread, 366)

      assert Threads.cleanup_resolved_threads(90) == 1
      assert Repo.get(Custyard.Thread, thread.id) == nil
    end

    test "purges resolved threads with a NULL source column at the standard bound" do
      # The DB column has no NOT NULL constraint (only the Ecto schema
      # default), so a legacy row or a bypass-the-schema insert can leave
      # source NULL. Force it directly, bypassing the changeset default.
      thread = insert_thread(state: :resolved)
      backdate_updated_at(thread, 91)

      Repo.update_all(
        from(c in Custyard.Thread, where: c.id == ^thread.id),
        set: [source: nil]
      )

      assert Threads.cleanup_resolved_threads(90) == 1
      assert Repo.get(Custyard.Thread, thread.id) == nil
    end

    test "dry run counts the retention split without deleting" do
      org = insert_organization()
      non_intake = insert_thread(organization_id: org.id, state: :resolved)
      intake_young = insert_thread(source: :public_intake, state: :resolved)
      intake_old = insert_thread(source: :public_intake, state: :resolved)
      backdate_updated_at(non_intake, 91)
      backdate_updated_at(intake_young, 120)
      backdate_updated_at(intake_old, 366)

      assert Threads.cleanup_resolved_threads(90, dry_run: true) == 2
      assert Repo.get(Custyard.Thread, non_intake.id)
      assert Repo.get(Custyard.Thread, intake_young.id)
      assert Repo.get(Custyard.Thread, intake_old.id)
    end

    test "purging cascades to the prospect so the access token stops resolving" do
      {token, hash} = Token.generate()
      thread = insert_thread(source: :public_intake, state: :resolved)
      prospect = insert_prospect(thread_id: thread.id, access_token_hash: hash)
      backdate_updated_at(thread, 366)

      assert {:ok, _thread} =
               Intake.get_thread_by_access_token(token, Process.get(:factory_tenant_id))

      assert Threads.cleanup_resolved_threads(90) == 1

      assert Repo.get(Prospect, prospect.id) == nil

      assert Intake.get_thread_by_access_token(token, Process.get(:factory_tenant_id)) ==
               {:error, :not_found}
    end

    test "run_cleanup applies the public-intake retention split" do
      intake_old = insert_thread(source: :public_intake, state: :resolved)
      intake_young = insert_thread(source: :public_intake, state: :resolved)
      backdate_updated_at(intake_old, 366)
      backdate_updated_at(intake_young, 120)

      %{resolved_threads: count} = Threads.run_cleanup(dry_run: true)
      assert count == 1
    end

    # The non-dry path was never exercised: cleanup_orphaned_contacts/1
    # expressed its anti-join as a DELETE-with-JOIN, which SQLite rejects,
    # so run_cleanup/1 raised on any real invocation. It is scheduled now
    # (Threads.RetentionSweep), so this pins the whole path.
    test "run_cleanup deletes for real, not only under dry_run" do
      intake_old = insert_thread(source: :public_intake, state: :resolved)
      intake_young = insert_thread(source: :public_intake, state: :resolved)
      backdate_updated_at(intake_old, 366)
      backdate_updated_at(intake_young, 120)

      counts = Threads.run_cleanup()

      assert counts.resolved_threads == 1
      refute Repo.get(Custyard.Thread, intake_old.id)
      assert Repo.get(Custyard.Thread, intake_young.id)
    end

    test "run_cleanup removes contacts left with no threads" do
      org = insert_organization()
      orphan = insert_contact(organization_id: org.id)
      kept = insert_contact(organization_id: org.id)
      _live = insert_thread(organization_id: org.id, contact_id: kept.id, state: :active)

      counts = Threads.run_cleanup()

      assert counts.orphaned_contacts >= 1
      refute Repo.get(Custyard.Contact, orphan.id)
      assert Repo.get(Custyard.Contact, kept.id)
    end
  end

  # --- helpers ---

  # Public-intake thread with a prospect message and a prospect row.
  defp intake_fixture(prospect_overrides) do
    thread = insert_thread(source: :public_intake, subject: "Intake question")

    insert_message(
      thread_id: thread.id,
      source: :prospect,
      sender_email: nil,
      body: "Hello, can you help me?"
    )

    prospect =
      insert_prospect(
        Keyword.merge(
          [
            thread_id: thread.id,
            email_captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
          ],
          prospect_overrides
        )
      )

    {thread, prospect}
  end

  # Re-read without preloaded associations so send_reply sees fresh consent.
  defp fresh(thread), do: Threads.get!(current_scope(), thread.id)

  defp backdate_updated_at(thread, days) do
    backdated =
      DateTime.utc_now()
      |> DateTime.add(-days * 24 * 60 * 60, :second)
      |> DateTime.truncate(:second)

    Repo.update_all(
      from(c in Custyard.Thread, where: c.id == ^thread.id),
      set: [updated_at: backdated]
    )
  end

  describe "reply identity with inbound channels (D3)" do
    setup do
      org = insert_organization(name: "Channel Corp")
      contact = insert_contact(organization_id: org.id, email: "customer@example.com")

      route =
        insert_inbound_route(
          organization_id: org.id,
          route_type: :general,
          source: :lettermint,
          from_address: "route@acme.example.com",
          lettermint_route_id: "lm_#{System.unique_integer([:positive])}",
          lettermint_route_domain: "r#{System.unique_integer([:positive])}.lettermint.app"
        )

      %{org: org, contact: contact, route: route}
    end

    test "the channel public address wins over the route from_address", %{
      org: org,
      contact: contact,
      route: route
    } do
      channel =
        insert_inbound_channel(
          inbound_route_id: route.id,
          public_address: "help@acme.example.com",
          display_name: "Acme Help",
          state: :active
        )

      thread =
        insert_thread(
          organization_id: org.id,
          contact_id: contact.id,
          inbound_channel_id: channel.id
        )

      {:ok, message} =
        Threads.send_reply(thread, "Reply", staff_email: "agent@corp.com")

      assert message.sender_email == "help@acme.example.com"

      assert Threads.reply_identity(thread, staff_email: "agent@corp.com") == %{
               address: "help@acme.example.com",
               name: "Acme Help",
               source: :channel
             }
    end

    test "a channel without a display name reports the tenant name", %{
      org: org,
      route: route
    } do
      channel = insert_inbound_channel(inbound_route_id: route.id, state: :active)
      thread = insert_thread(organization_id: org.id, inbound_channel_id: channel.id)

      assert %{name: "Tenant", source: :channel} =
               Threads.reply_identity(thread)
    end

    test "the ingress fallback replies from local+token@domain", %{org: org, route: route} do
      channel =
        insert_inbound_channel(
          inbound_route_id: route.id,
          public_address: "help@acme.example.com",
          reply_from: :ingress_address,
          state: :active
        )

      thread = insert_thread(organization_id: org.id, inbound_channel_id: channel.id)

      expected = "help+#{channel.ingress_token}@#{route.lettermint_route_domain}"
      assert Custyard.InboundChannels.ingress_address(channel) == expected

      {:ok, message} = Threads.send_reply(thread, "Reply")
      assert message.sender_email == expected

      assert %{address: ^expected, source: :channel} = Threads.reply_identity(thread)
    end

    test "a preloaded channel association is used without a lookup", %{org: org, route: route} do
      channel =
        insert_inbound_channel(
          inbound_route_id: route.id,
          public_address: "help@acme.example.com",
          state: :active
        )

      thread =
        insert_thread(organization_id: org.id, inbound_channel_id: channel.id)
        |> Repo.preload(:inbound_channel)

      assert %{address: "help@acme.example.com", source: :channel} =
               Threads.reply_identity(thread)
    end

    test "without a channel tenant setup is required", %{org: org} do
      thread = insert_thread(organization_id: org.id)

      assert Threads.reply_identity(thread, staff_email: "agent@corp.com") == %{
               address: nil,
               name: "Tenant",
               source: :platform
             }
    end

    test "public intake uses the tenant's support channel", %{route: route} do
      channel = insert_inbound_channel(inbound_route_id: route.id, state: :active)

      thread =
        insert_thread(
          source: :public_intake,
          tenant_id: route.tenant_id,
          organization_id: nil,
          inbound_channel_id: channel.id
        )

      assert Threads.reply_identity(thread) == %{
               address: channel.public_address,
               name: "Tenant",
               source: :channel
             }
    end
  end
end
