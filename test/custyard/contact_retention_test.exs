defmodule Custyard.ContactRetentionTest do
  use Custyard.DataCase, async: true
  import Custyard.Factory
  alias Custyard.{Contact, Organizations, PortalCredentials, Repo, Threads}
  alias Custyard.Email.Outbound

  test "cleanup preserves the default reply contact for portal threads without explicit contacts" do
    customer = insert_organization()
    contact = insert_contact(organization_id: customer.id)
    scope = staff_scope(customer.tenant_id)
    {:ok, customer} = Organizations.update(scope, customer, %{default_contact_id: contact.id})
    thread = insert_thread(organization_id: customer.id, contact_id: nil, source: :portal)
    orphan = insert_contact(organization_id: customer.id)

    assert Outbound.reply_recipient(thread) == {:ok, contact.email}
    assert Threads.cleanup_orphaned_contacts(dry_run: true) == 1
    assert Repo.get(Contact, orphan.id)
    assert Threads.cleanup_orphaned_contacts() == 1
    assert Repo.get(Contact, contact.id)
    assert Repo.reload!(customer).default_contact_id == contact.id
    assert Outbound.reply_recipient(thread) == {:ok, contact.email}
    refute Repo.get(Contact, orphan.id)
  end

  test "cleanup preserves active and revoked portal contact attribution without thread references" do
    customer = insert_organization()
    active_contact = insert_contact(organization_id: customer.id)
    revoked_contact = insert_contact(organization_id: customer.id)
    scope = staff_scope(customer.tenant_id)
    {:ok, active, _} = PortalCredentials.issue(scope, customer.id, active_contact.id)
    {:ok, revoked, _} = PortalCredentials.issue(scope, customer.id, revoked_contact.id)
    {:ok, revoked} = PortalCredentials.revoke(scope, revoked)
    orphan = insert_contact(organization_id: customer.id)

    assert Threads.cleanup_orphaned_contacts(dry_run: true) == 1
    assert Threads.cleanup_orphaned_contacts() == 1
    assert Repo.get(Contact, active_contact.id)
    assert Repo.get(Contact, revoked_contact.id)
    assert Repo.reload!(active).contact_id == active_contact.id
    assert Repo.reload!(revoked).contact_id == revoked_contact.id
    assert PortalCredentials.reply_contact(active).id == active_contact.id
    refute Repo.get(Contact, orphan.id)
  end

  test "thread references remain protected and the sweep removes only true orphans across tenants" do
    first = insert_organization()
    second = insert_organization(tenant_id: insert_tenant().id)
    contact = insert_contact(organization_id: first.id, email: "same@example.com")
    foreign_orphan = insert_contact(organization_id: second.id, email: contact.email)
    insert_thread(organization_id: first.id, contact_id: contact.id)

    assert Threads.cleanup_orphaned_contacts(dry_run: true) == 1
    assert Threads.cleanup_orphaned_contacts() == 1
    assert Repo.get(Contact, contact.id)
    refute Repo.get(Contact, foreign_orphan.id)
  end
end
