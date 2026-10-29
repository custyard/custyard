defmodule Custyard.Email.OutboundPauseTest do
  use Custyard.DataCase, async: false

  import Custyard.Factory
  import Swoosh.TestAssertions

  alias Custyard.{AuditEvent, Message, Repo, StaffAccount, Tenant, Tenants, Threads}
  alias Custyard.Email.{Outbound, OutboundQueue}

  setup :set_swoosh_global

  setup do
    tenant = insert_tenant()
    admin = insert_staff_account(tenant_id: tenant.id, role: "admin")
    customer = insert_organization(tenant_id: tenant.id)
    contact = insert_contact(organization_id: customer.id)
    channel = configure_tenant_email(tenant.id)
    thread = insert_thread(organization_id: customer.id, contact_id: contact.id)
    {:ok, reply} = Threads.send_reply(thread, "A saved reply")
    %{tenant: tenant, admin: admin, reply: reply, channel: channel, contact: contact}
  end

  test "pause holds existing replies; resume delivers the same reply once", c do
    assert {:ok, paused} = Tenants.set_outbound_paused(c.admin, c.tenant.id, true)
    assert paused.outbound_paused
    assert OutboundQueue.drain_pending() == 0
    assert {:error, :outbound_paused, held} = Outbound.deliver(c.reply)
    assert held.delivery_status == :pending
    assert held.delivery_attempted_at == nil
    assert held.delivery_payload_hash == nil
    assert_no_email_sent()

    assert {:ok, _} = Tenants.set_outbound_paused(c.admin, c.tenant.id, false)
    assert OutboundQueue.drain_pending() == 1
    assert_email_sent(to: c.contact.email)
    assert Repo.reload!(c.reply).delivery_status == :sent
    assert OutboundQueue.drain_pending() == 0

    events = Repo.all(AuditEvent) |> Enum.filter(&(&1.event_type == :outbound_pause_changed))
    assert Enum.map(events, & &1.payload["paused"]) |> Enum.sort() == [false, true]
    assert Enum.all?(events, &(&1.payload["staff_id"] == c.admin.id))
  end

  test "the installation recovery switch holds all replies without a provider attempt", c do
    original = Application.get_env(:custyard, :outbound_delivery_enabled)
    Application.put_env(:custyard, :outbound_delivery_enabled, false)

    on_exit(fn ->
      if is_nil(original),
        do: Application.delete_env(:custyard, :outbound_delivery_enabled),
        else: Application.put_env(:custyard, :outbound_delivery_enabled, original)
    end)

    assert OutboundQueue.drain_pending() == 0
    assert {:error, :outbound_paused, pending} = Outbound.deliver(c.reply)
    assert pending.delivery_status == :pending
    assert pending.delivery_attempted_at == nil
    assert pending.delivery_payload_hash == nil
    assert_no_email_sent()

    Application.put_env(:custyard, :outbound_delivery_enabled, true)
    assert OutboundQueue.drain_pending() == 1
    assert Repo.reload!(c.reply).delivery_status == :sent
    assert_email_sent(to: c.contact.email)
  end

  test "pause does not allow a held tenant to starve other tenants", c do
    assert {:ok, _} = Tenants.set_outbound_paused(c.admin, c.tenant.id, true)
    other = insert_tenant()
    configure_tenant_email(other.id)
    customer = insert_organization(tenant_id: other.id)
    contact = insert_contact(organization_id: customer.id)
    thread = insert_thread(organization_id: customer.id, contact_id: contact.id)
    assert {:ok, reply} = Threads.send_reply(thread, "Other tenant's reply")

    assert OutboundQueue.drain_pending() == 1
    assert Repo.reload!(reply).delivery_status == :sent
    assert Repo.reload!(c.reply).delivery_status == :pending
    assert_email_sent(to: contact.email)
  end

  test "only a current administrator of this tenant may change the pause", c do
    agent = insert_staff_account(tenant_id: c.tenant.id, role: "agent")
    foreign = insert_tenant()
    assert {:error, :unauthorized} = Tenants.set_outbound_paused(agent, c.tenant.id, true)
    assert {:error, :unauthorized} = Tenants.set_outbound_paused(c.admin, foreign.id, true)

    assert {:error, :unauthorized} =
             Tenants.set_outbound_paused(%{agent | role: "admin"}, c.tenant.id, true)

    c.admin
    |> Ecto.Changeset.change(session_claim: StaffAccount.generate_session_claim())
    |> Repo.update!()

    assert {:error, :unauthorized} = Tenants.set_outbound_paused(c.admin, c.tenant.id, true)
    refute Repo.get!(Tenant, c.tenant.id).outbound_paused
    refute Repo.get!(Tenant, foreign.id).outbound_paused
  end

  test "ordinary tenant settings cannot bypass pause authorization", c do
    assert {:ok, _} =
             Tenants.update_tenant_for_staff(c.admin, c.tenant.id, %{"outbound_paused" => true})

    refute Repo.get!(Tenant, c.tenant.id).outbound_paused
  end

  test "a queued reply cannot use a sending channel paused after enqueue", c do
    c.channel |> Ecto.Changeset.change(state: :paused) |> Repo.update!()
    assert {:error, :reply_channel_inactive, failed} = Outbound.deliver(c.reply)
    assert failed.delivery_status == :failed
    assert failed.delivery_failure_kind == :configuration
    assert failed.delivery_attempted_at == nil
    assert failed.delivery_error_code == "reply_channel_inactive"
    assert_no_email_sent()
  end

  test "new pending messages remain preserved while paused", c do
    assert {:ok, _} = Tenants.set_outbound_paused(c.admin, c.tenant.id, true)

    assert {:ok, additional} =
             Threads.send_reply(Repo.preload(c.reply, :thread).thread, "More work")

    assert OutboundQueue.drain_pending() == 0
    assert Repo.get!(Message, additional.id).delivery_status == :pending
    assert_no_email_sent()
  end

  test "a queued sender cannot outlive a channel identity change", c do
    c.channel |> Ecto.Changeset.change(public_address: "changed@example.com") |> Repo.update!()
    assert {:error, :reply_identity_changed, failed} = Outbound.deliver(c.reply)
    assert failed.delivery_error_code == "reply_identity_changed"
    assert failed.delivery_attempted_at == nil
    assert_no_email_sent()
  end
end
