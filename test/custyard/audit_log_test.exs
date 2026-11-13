defmodule Custyard.AuditLogTest do
  # SQLite doesn't support async tests due to database locking
  use Custyard.DataCase, async: false

  import Custyard.Factory

  alias Custyard.{AuditEvent, AuditLog, InstanceAdmin, InstanceAdmins, Tenants, Threads}
  alias Custyard.AuditLog.Entry

  @sender "digest@sender.example.com"

  setup do
    tenant = insert_tenant(name: "Northwind")
    Process.put(:factory_tenant_id, tenant.id)
    staff = insert_staff_account(role: "admin", tenant_id: tenant.id, email: "ada@northwind.test")
    org = insert_organization(tenant_id: tenant.id, name: "Acme Fittings")
    contact = insert_contact(organization_id: org.id, email: @sender)

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

  defp entries(scope, opts \\ []) do
    {:ok, %{entries: entries}} = AuditLog.for_tenant(scope, opts)
    entries
  end

  defp instance_entries(admin, opts \\ []) do
    {:ok, %{entries: entries}} = AuditLog.for_instance(admin, opts)
    entries
  end

  defp instance_admin(email \\ "root@install.test") do
    {:created, admin} = InstanceAdmins.create_admin(email)
    admin
  end

  # A row as it was stored before payloads were minimized: straight into the
  # table, past the changeset.
  defp insert_legacy_event(tenant_id, type, source, payload, opts \\ []) do
    {1, [%{id: id}]} =
      Repo.insert_all(
        AuditEvent,
        [
          %{
            tenant_id: tenant_id,
            event_type: type,
            source: source,
            payload: payload,
            thread_id: opts[:thread_id],
            message_id: opts[:message_id],
            inserted_at: DateTime.utc_now(:second)
          }
        ],
        returning: [:id]
      )

    id
  end

  describe "topics" do
    test "every audit event type belongs to exactly one topic" do
      listed = AuditLog.topics() |> Map.values() |> List.flatten()

      assert Enum.sort(listed) == Enum.sort(AuditEvent.event_types())
      assert listed == Enum.uniq(listed)

      for type <- AuditEvent.event_types() do
        assert is_binary(AuditLog.topic_label(AuditLog.topic(type)))
      end
    end

    test "the tenant filters start with actions and end with everything" do
      assert Enum.map(AuditLog.categories(), & &1.id) ==
               ~w(actions conversations customers channels workspace mail everything)

      assert AuditLog.default_category() == "actions"
      assert AuditLog.category("mail") == "mail"
      assert AuditLog.category("installation") == "actions"
      assert AuditLog.category("nonsense") == "actions"
      assert AuditLog.category(nil) == "actions"
    end
  end

  describe "for_tenant/2 access" do
    test "is refused to an agent, a removed admin and a stale session", c do
      insert_audit_event(event_type: :outbound_pause_changed, source: "staff")

      assert AuditLog.for_tenant(staff_scope(c.tenant.id, "agent")) == {:error, :unauthorized}

      removed = staff_scope(c.tenant.id)
      Repo.delete!(Repo.get!(Custyard.StaffAccount, removed.staff_id))
      assert AuditLog.for_tenant(removed) == {:error, :unauthorized}

      assert AuditLog.for_tenant(%{c.scope | session_claim: "stale"}) == {:error, :unauthorized}
      assert {:ok, %{entries: [_]}} = AuditLog.for_tenant(c.scope)
    end

    test "is refused while the tenant is suspended", c do
      admin = instance_admin()
      {:ok, _} = Tenants.set_status(admin, c.tenant.id, "suspended")

      assert AuditLog.for_tenant(c.scope) == {:error, :unauthorized}
    end

    test "lists the tenant's own events and no other tenant's", c do
      other = insert_tenant(name: "Contoso")
      other_scope = staff_scope(other.id)
      other_org = insert_organization(tenant_id: other.id, name: "Other customer")

      other_thread =
        insert_thread(organization_id: other_org.id, state: :active, subject: "Their secret")

      {:ok, _} = Threads.set_state(other_scope, other_thread.id, :resolved)
      {:ok, _} = Threads.set_state(c.scope, c.thread.id, :waiting)

      assert [%Entry{} = mine] = entries(c.scope, category: "everything")
      assert mine.thread == %{id: c.thread.id, subject: "Refund request"}

      assert [%Entry{} = theirs] = entries(other_scope, category: "everything")
      assert theirs.thread == %{id: other_thread.id, subject: "Their secret"}

      # Asking for the other tenant's thread by id finds nothing.
      assert {:ok, %{entries: [], thread: nil}} =
               AuditLog.for_tenant(c.scope, thread_id: other_thread.id, category: "everything")
    end

    test "leaves out installation events", c do
      instance_admin()

      assert entries(c.scope, category: "everything") == []
    end
  end

  describe "for_tenant/2 filters and pages" do
    setup c do
      {:ok, _} = Threads.set_state(c.scope, c.thread.id, :waiting)
      insert_audit_event(event_type: :webhook_received, thread_id: c.thread.id)
      insert_audit_event(event_type: :outbound_pause_changed, source: "staff")
      insert_audit_event(event_type: :channel_token_revealed, source: "inbound_channels")
      insert_audit_event(event_type: :slug_released, source: "staff")
      :ok
    end

    defp types(entries), do: Enum.map(entries, & &1.event_type)

    test "actions, the default, is everything but mail processing, newest first", c do
      expected = [
        :slug_released,
        :channel_token_revealed,
        :outbound_pause_changed,
        :thread_state_changed
      ]

      assert types(entries(c.scope)) == expected
      assert types(entries(c.scope, category: "actions")) == expected
      assert types(entries(c.scope, category: "nonsense")) == expected
    end

    test "each topic lists its own events", c do
      assert types(entries(c.scope, category: "conversations")) == [:thread_state_changed]
      assert types(entries(c.scope, category: "customers")) == [:slug_released]
      assert types(entries(c.scope, category: "channels")) == [:channel_token_revealed]
      assert types(entries(c.scope, category: "workspace")) == [:outbound_pause_changed]
      assert types(entries(c.scope, category: "mail")) == [:webhook_received]
      assert length(entries(c.scope, category: "everything")) == 5

      for entry <- entries(c.scope, category: "everything") do
        assert entry.topic == AuditLog.topic(entry.event_type)
      end
    end

    test "a thread filter keeps the events of that thread", c do
      other = insert_thread(organization_id: c.org.id, state: :active, subject: "Other")
      {:ok, _} = Threads.set_state(c.scope, other.id, :resolved)

      assert {:ok, page} =
               AuditLog.for_tenant(c.scope, thread_id: c.thread.id, category: "everything")

      assert page.thread == %{id: c.thread.id, subject: "Refund request"}
      assert types(page.entries) == [:webhook_received, :thread_state_changed]
      assert Enum.all?(page.entries, &(&1.thread.id == c.thread.id))

      # The filters combine.
      assert types(entries(c.scope, thread_id: c.thread.id)) == [:thread_state_changed]

      # No thread filter, no thread.
      assert {:ok, %{thread: nil}} = AuditLog.for_tenant(c.scope)
    end

    test "pages hold fifty entries and name where the next one starts", c do
      for _ <- 1..(AuditLog.page_size() + 5) do
        insert_audit_event(event_type: :outbound_pause_changed, source: "staff")
      end

      assert {:ok, %{entries: first, older: older}} =
               AuditLog.for_tenant(c.scope, category: "workspace")

      assert AuditLog.page_size() == 50
      assert length(first) == 50
      assert older == List.last(first).id

      assert {:ok, %{entries: second, older: nil}} =
               AuditLog.for_tenant(c.scope, category: "workspace", before: older)

      assert length(second) == 6
      assert Enum.all?(second, &(&1.id < older))

      ids = Enum.map(first ++ second, & &1.id)
      assert ids == Enum.sort(ids, :desc)
      assert ids == Enum.uniq(ids)
    end

    test "a page of exactly fifty has no next page", c do
      for _ <- 1..(AuditLog.page_size() - 1) do
        insert_audit_event(event_type: :outbound_pause_changed, source: "staff")
      end

      assert {:ok, %{entries: entries, older: nil}} =
               AuditLog.for_tenant(c.scope, category: "workspace")

      assert length(entries) == 50
    end

    test "a before value that is not a positive integer is ignored", c do
      for before <- [nil, 0, -3, "12", 1.5] do
        assert length(entries(c.scope, before: before)) == 4
      end
    end
  end

  describe "for_tenant/2 entries" do
    test "a state change names the staff member, the states, the thread and the customer", c do
      {:ok, _} = Threads.set_state(c.scope, c.thread.id, :resolved)

      assert [%Entry{} = entry] = entries(c.scope)
      assert entry.event_type == :thread_state_changed
      assert entry.topic == :conversations
      assert entry.actor == "ada@northwind.test"
      assert entry.summary == "Changed the state from active to resolved"
      assert entry.thread == %{id: c.thread.id, subject: "Refund request"}
      assert entry.customer == %{id: c.org.id, name: "Acme Fittings"}
      assert entry.tenant == nil
      assert %DateTime{} = entry.at
    end

    test "ignoring a sender names the address", c do
      {:ok, _} = Threads.ignore_sender(c.scope, c.thread.id)
      {:ok, _} = Threads.unignore_sender(c.scope, c.thread.id)

      assert [stopped, ignored] = entries(c.scope)
      assert ignored.summary == "Ignored the sender #{@sender}"
      assert stopped.summary == "Stopped ignoring the sender #{@sender}"
      assert ignored.actor == "ada@northwind.test"
    end

    test "a dismissal shows as a state change and a note", c do
      {:ok, _} = Threads.dismiss(c.scope, c.thread.id)

      assert [note, change] = entries(c.scope)
      assert note.summary == "Added an internal note"
      assert change.summary == "Changed the state from active to resolved"
      # The note event names the thread only; the customer comes from it.
      assert note.customer == %{id: c.org.id, name: "Acme Fittings"}
      assert note.thread.id == c.thread.id
    end

    test "a staff member who was removed is not named", c do
      other =
        insert_staff_account(role: "admin", tenant_id: c.tenant.id, email: "gone@northwind.test")

      other_scope = Custyard.Scope.for_staff(other, c.tenant)
      {:ok, _} = Threads.set_state(other_scope, c.thread.id, :resolved)
      {:ok, _} = Tenants.remove_staff(c.staff, c.tenant.id, other.id)

      assert [removal, change] = entries(c.scope)
      assert change.actor == "Removed staff account"
      assert removal.actor == "ada@northwind.test"
      assert removal.summary == "Removed an admin staff account"
      assert removal.topic == :workspace
    end

    test "an instance admin's action is shown without the admin's address", c do
      admin = instance_admin("root@install.test")
      {:ok, _} = Tenants.set_status(admin, c.tenant.id, "suspended")
      {:ok, _} = Tenants.set_status(admin, c.tenant.id, "active")

      assert [resumed, suspended] = entries(c.scope)
      assert suspended.actor == "Instance admin"
      assert suspended.summary == "Suspended the workspace"
      assert resumed.summary == "Resumed the workspace"
      refute inspect([resumed, suspended]) =~ "root@install.test"
    end

    test "a channel event names the channel's public address", c do
      channel = insert_inbound_channel(tenant_id: c.tenant.id)

      insert_audit_event(
        event_type: :channel_state_changed,
        source: "inbound_channels",
        payload: %{
          "channel_id" => channel.id,
          "from" => "pending_verification",
          "to" => "active"
        }
      )

      assert [entry] = entries(c.scope)

      assert entry.summary ==
               "Changed the support channel #{channel.public_address} from pending verification to active"

      assert entry.actor == "System"
    end

    test "a thread without a customer or a subject still lists", c do
      thread = insert_thread(tenant_id: c.tenant.id, source: :public_intake, state: :new)
      {:ok, _} = Threads.set_state(c.scope, thread.id, :resolved)
      Repo.update_all(from(t in Custyard.Thread, where: t.id == ^thread.id), set: [subject: ""])

      assert [entry] = entries(c.scope)
      assert entry.thread == %{id: thread.id, subject: ""}
      assert entry.customer == nil
      assert entry.summary == "Changed the state from new to resolved"
    end

    test "every event type has an actor and a summary, with or without its payload", c do
      for type <- AuditEvent.event_types(), type in List.flatten(tenant_types()) do
        insert_legacy_event(c.tenant.id, type, "staff", nil)
        insert_legacy_event(c.tenant.id, type, "staff", %{})
      end

      {:ok, first} = AuditLog.for_tenant(c.scope, category: "everything")
      {:ok, second} = AuditLog.for_tenant(c.scope, category: "everything", before: first.older)
      listed = first.entries ++ second.entries

      assert second.older == nil
      assert length(listed) == 2 * length(List.flatten(tenant_types()))

      for entry <- listed do
        assert is_binary(entry.actor) and entry.actor != ""
        assert is_binary(entry.summary) and entry.summary != ""
      end
    end

    defp tenant_types do
      AuditLog.topics() |> Map.delete(:installation) |> Map.values()
    end
  end

  describe "for_tenant/2 and what a stored row may hold" do
    test "a row from before payloads were minimized shows no address and no message text", c do
      insert_legacy_event(
        c.tenant.id,
        :slug_released,
        "staff",
        %{
          "slug" => "acme",
          "email" => "prospect@private.example.com",
          "staff_email" => "old-staff@private.example.com",
          "staff_id" => c.staff.id
        }
      )

      insert_legacy_event(
        c.tenant.id,
        :webhook_received,
        "email",
        %{
          "source" => "email",
          "from" => "customer@private.example.com",
          "subject" => "Private subject line",
          "body" => "Private message body"
        },
        thread_id: c.thread.id,
        message_id: "<abc123@private.example.com>"
      )

      listed = entries(c.scope, category: "everything")
      assert [received, released] = listed

      assert released.summary == "Released the slug acme"
      assert released.actor == "ada@northwind.test"
      assert received.summary == "Received an inbound message (email)"

      shown = inspect(listed)
      refute shown =~ "private.example.com"
      refute shown =~ "Private subject line"
      refute shown =~ "Private message body"
      refute shown =~ "abc123"
    end

    test "a value outside the allowlist of its key is not shown", c do
      insert_legacy_event(c.tenant.id, :thread_state_changed, "staff", %{
        "staff_id" => "ada@private.example.com",
        "from" => "<script>alert(1)</script>",
        "to" => "resolved"
      })

      assert [entry] = entries(c.scope)
      assert entry.summary == "Changed the state to resolved"
      assert entry.actor == "Staff"
    end

    test "a staff id of another tenant is not resolved to an address", c do
      foreign = insert_staff_account(tenant_id: insert_tenant().id, email: "spy@other.test")

      insert_audit_event(
        event_type: :outbound_pause_changed,
        source: "staff",
        payload: %{"staff_id" => foreign.id, "paused" => true}
      )

      assert [entry] = entries(c.scope)
      assert entry.actor == "Removed staff account"
    end
  end

  describe "for_instance/2" do
    setup c do
      admin = instance_admin("root@install.test")
      {:ok, _} = Tenants.set_status(admin, c.tenant.id, "suspended")
      {:ok, _} = Tenants.set_status(admin, c.tenant.id, "active")
      {:ok, admin: admin}
    end

    test "is refused to anyone but a current instance admin", c do
      assert AuditLog.for_instance(c.staff) == {:error, :unauthorized}
      assert AuditLog.for_instance(c.scope) == {:error, :unauthorized}
      assert AuditLog.for_instance(nil) == {:error, :unauthorized}
      assert AuditLog.for_instance(%InstanceAdmin{}) == {:error, :unauthorized}

      assert AuditLog.for_instance(%{c.admin | session_claim: "stale"}) ==
               {:error, :unauthorized}

      other = instance_admin("second@install.test")
      {:ok, _} = InstanceAdmins.remove_admin("second@install.test")
      assert AuditLog.for_instance(other) == {:error, :unauthorized}

      assert {:ok, %{entries: [_ | _]}} = AuditLog.for_instance(c.admin)
    end

    test "lists installation events and what instance admins did to a tenant", c do
      assert [resumed, suspended, created] = instance_entries(c.admin)

      assert created.event_type == :instance_admin_created
      assert created.topic == :installation
      assert created.actor == "Installation"
      assert created.summary == "Created the instance admin account root@install.test"
      assert created.tenant == nil

      assert suspended.actor == "root@install.test"
      assert suspended.summary == "Suspended the workspace"
      assert suspended.tenant == %{id: c.tenant.id, name: "Northwind"}
      assert resumed.summary == "Resumed the workspace"
    end

    test "names a removed instance admin by nothing but the fact", c do
      instance_admin("second@install.test")
      {:ok, _} = InstanceAdmins.remove_admin("second@install.test")

      assert [removed, created | _] = instance_entries(c.admin)
      assert removed.summary == "Removed an instance admin account"
      assert created.summary == "Created an instance admin account"
    end

    test "leaves out everything a tenant did itself", c do
      {:ok, _} = Threads.set_state(c.scope, c.thread.id, :resolved)
      {:ok, _} = Threads.ignore_sender(c.scope, c.thread.id)
      {:ok, _} = Tenants.set_outbound_paused(c.staff, c.tenant.id, true)
      insert_audit_event(event_type: :webhook_received, thread_id: c.thread.id)
      insert_audit_event(event_type: :channel_token_revealed, source: "inbound_channels")

      assert length(entries(c.scope, category: "everything")) == 7

      listed = instance_entries(c.admin)

      assert Enum.map(listed, & &1.event_type) == [
               :tenant_status_changed,
               :tenant_status_changed,
               :instance_admin_created
             ]

      shown = inspect(listed)
      refute shown =~ "Refund request"
      refute shown =~ "Acme Fittings"
      refute shown =~ @sender
      refute shown =~ "ada@northwind.test"
    end

    test "never shows a thread, a customer or tenant staff, whatever the row holds", c do
      insert_audit_event(
        event_type: :staff_removed,
        source: "instance_admin",
        thread_id: c.thread.id,
        organization_id: c.org.id,
        payload: %{"staff_id" => c.staff.id, "actor_staff_id" => c.staff.id, "role" => "admin"}
      )

      insert_audit_event(
        event_type: :sender_ignored,
        source: "instance_admin",
        thread_id: c.thread.id,
        payload: %{"staff_id" => c.staff.id, "contact_id" => c.contact.id, "ignored" => true}
      )

      assert [ignored, removed | _] = instance_entries(c.admin)

      for entry <- [ignored, removed] do
        assert entry.thread == nil
        assert entry.customer == nil
        assert entry.actor == "Tenant staff"
        assert entry.tenant == %{id: c.tenant.id, name: "Northwind"}
      end

      assert removed.summary == "Removed an admin staff account"
      assert ignored.summary == "Ignored the sender"

      shown = inspect([ignored, removed])
      refute shown =~ "Refund request"
      refute shown =~ "Acme Fittings"
      refute shown =~ @sender
      refute shown =~ "ada@northwind.test"
    end

    test "pages like the tenant timeline", c do
      for _ <- 1..AuditLog.page_size() do
        insert_legacy_event(nil, :installation_configured, "instance_admin", %{
          "instance_admin_id" => c.admin.id
        })
      end

      assert {:ok, %{entries: first, older: older}} = AuditLog.for_instance(c.admin)
      assert length(first) == 50
      assert older == List.last(first).id
      assert hd(first).summary == "Completed installation setup"
      assert hd(first).actor == "root@install.test"

      assert {:ok, %{entries: second, older: nil}} = AuditLog.for_instance(c.admin, before: older)
      assert length(second) == 3
    end

    test "every installation event type has an actor and a summary", c do
      for type <- AuditLog.topics().installation do
        insert_legacy_event(nil, type, "instance_admin", nil)
      end

      for entry <- instance_entries(c.admin) do
        assert is_binary(entry.actor) and entry.actor != ""
        assert is_binary(entry.summary) and entry.summary != ""
      end
    end
  end
end
