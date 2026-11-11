defmodule CustyardWeb.Staff.ReplyAddressingTest do
  use CustyardWeb.ConnCase, async: false
  import Custyard.Factory
  import Phoenix.LiveViewTest
  alias Custyard.{Message, Organizations, Repo, Scope, Tenants, Threads}
  alias Custyard.Email.Outbound
  alias Ecto.Changeset

  setup %{conn: conn} do
    staff = insert_staff_account(role: "admin")
    scope = Scope.for_staff(staff, Tenants.get_tenant!(staff.tenant_id))
    org = insert_organization()
    contact = insert_contact(organization_id: org.id)
    conn = conn |> init_test_session(%{}) |> put_staff_session(staff)
    %{conn: conn, staff: staff, scope: scope, org: org, contact: contact}
  end

  test "portal replies choose a tenant address and snapshot it with the recipient", c do
    support = insert_inbound_channel(state: :active, public_address: "support@example.org")

    billing =
      insert_inbound_channel(
        state: :active,
        public_address: "billing@example.org",
        display_name: "Billing"
      )

    {:ok, _} = Organizations.update(c.scope, c.org, %{default_contact_id: c.contact.id})
    thread = insert_thread(organization_id: c.org.id, source: :portal, contact_id: nil)
    {:ok, view, _} = live(c.conn, "/app/threads/#{thread.id}")
    assert has_element?(view, "#staff-reply-from option[value='#{support.id}']")
    assert has_element?(view, "#staff-reply-from option[value='#{billing.id}']")

    assert has_element?(
             view,
             "[data-testid=composer-from-identity]",
             "Choose a tenant sending address"
           )

    assert has_element?(view, "[data-testid=staff-reply-to]", c.contact.email)

    view
    |> form("#staff-reply-form", body: "Billing reply", reply_channel_id: to_string(billing.id))
    |> render_change()

    assert has_element?(view, "[data-testid=composer-from-identity]", "billing@example.org")

    view
    |> form("#staff-reply-form", body: "Billing reply", reply_channel_id: to_string(billing.id))
    |> render_submit()

    [reply] = Repo.all(Ecto.assoc(thread, :messages))
    assert reply.sender_email == "billing@example.org"
    assert reply.inbound_channel_id == billing.id
    assert reply.to_addresses == [c.contact.email]
    assert is_nil(Repo.reload!(thread).inbound_channel_id)
  end

  test "forged or no-longer-active From choices cannot enqueue a reply", c do
    own = insert_inbound_channel(state: :active)
    foreign = insert_inbound_channel(tenant_id: insert_tenant().id, state: :active)
    thread = insert_thread(organization_id: c.org.id, contact_id: c.contact.id, source: :portal)
    {:ok, view, _} = live(c.conn, "/app/threads/#{thread.id}")
    refute has_element?(view, "#staff-reply-from option[value='#{foreign.id}']")
    Repo.update!(Changeset.change(own, state: :paused))

    for id <- [nil, "", "invalid", foreign.id, own.id] do
      assert {:error, :reply_channel_required} =
               Threads.send_reply(thread, "Blocked", staff: c.staff, reply_channel_id: id)
    end

    render_submit(view, "send_reply", %{
      "body" => "Blocked",
      "reply_channel_id" => to_string(foreign.id)
    })

    assert has_element?(view, "#flash-error", "Choose an active tenant email address")
    assert Repo.aggregate(Message, :count) == 0
  end

  test "a reply that never reached a provider can recover its missing recipient and From", c do
    channel = configure_tenant_email(c.org.tenant_id, public_address: "billing@example.org")
    thread = insert_thread(organization_id: c.org.id, source: :portal, contact_id: nil)
    {:ok, queued} = Threads.send_reply(thread, "Saved reply")
    assert {:error, :no_recipient_email, failed} = Outbound.deliver(queued)
    assert failed.to_addresses == []
    assert is_nil(failed.delivery_payload_hash)
    assert is_nil(failed.delivery_attempted_at)
    {:ok, _} = Organizations.update(c.scope, c.org, %{default_contact_id: c.contact.id})

    assert {:error, :recipient_changed} =
             Outbound.retry(c.scope, failed,
               reply_channel_id: channel.id,
               expected_recipient: "previous@example.org"
             )

    assert Repo.reload!(failed).delivery_status == :failed
    assert {:ok, retried} = Outbound.retry(c.scope, failed, reply_channel_id: channel.id)
    assert retried.to_addresses == [c.contact.email]
    assert retried.sender_email == channel.public_address
    assert retried.body == "Saved reply"
    assert {:ok, sent} = Outbound.deliver(retried)
    assert sent.delivery_status == :sent
  end

  test "retry never restores recipients after an envelope was already frozen", c do
    channel = configure_tenant_email(c.org.tenant_id)
    thread = insert_thread(organization_id: c.org.id, source: :portal, contact_id: nil)
    {:ok, queued} = Threads.send_reply(thread, "Saved reply")
    assert {:error, :no_recipient_email, failed} = Outbound.deliver(queued)
    failed = Repo.update!(Changeset.change(failed, delivery_payload_hash: "already-reviewed"))
    {:ok, _} = Organizations.update(c.scope, c.org, %{default_contact_id: c.contact.id})
    assert {:ok, retried} = Outbound.retry(c.scope, failed, reply_channel_id: channel.id)
    assert retried.to_addresses == []
    assert {:error, :no_recipient_email, _} = Outbound.deliver(retried)
  end
end
