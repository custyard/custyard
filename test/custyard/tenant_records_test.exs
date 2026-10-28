defmodule Custyard.TenantRecordsTest do
  use Custyard.DataCase
  import Custyard.Factory
  alias Custyard.{Attachments, Message, PortalCredentials, Repo, Tenant}

  defp tenant(name) do
    %Tenant{} |> Tenant.changeset(%{name: name, slug: String.downcase(name)}) |> Repo.insert!()
  end

  defp admin_scope(tenant) do
    staff = insert_staff_account(tenant_id: tenant.id, role: "admin")
    Custyard.Scope.for_staff(staff, tenant)
  end

  defp customer(tenant) do
    insert_organization(tenant_id: tenant.id)
  end

  test "message and provider delivery ids deduplicate within each tenant" do
    a = tenant("Alpha")
    b = tenant("Beta")
    ca = insert_thread(tenant_id: a.id, organization_id: customer(a).id)
    cb = insert_thread(tenant_id: b.id, organization_id: customer(b).id)

    attrs = %{
      source: :email,
      body: "hello",
      message_id: "<same@example.com>",
      provider_delivery_id: "same-provider-id"
    }

    assert {:ok, ma} = Message.insert_idempotent(Map.put(attrs, :thread_id, ca.id))
    assert {:ok, mb} = Message.insert_idempotent(Map.put(attrs, :thread_id, cb.id))
    assert ma.id != mb.id
    assert ma.tenant_id == a.id
    assert mb.tenant_id == b.id
    assert {:ok, ^ma} = Message.insert_idempotent(Map.put(attrs, :thread_id, ca.id))
  end

  test "portal credentials are hashed, tenant bound and independently revoked" do
    a = tenant("Alpha")
    b = tenant("Beta")
    org = customer(a)
    assert {:ok, first, first_token} = PortalCredentials.issue(admin_scope(a), org.id)
    assert {:ok, second, second_token} = PortalCredentials.issue(admin_scope(a), org.id)
    refute first.token_hash == first_token
    assert {:ok, %{id: id}} = PortalCredentials.authenticate(first_token, a.id)
    assert id == first.id
    assert {:error, :not_found} = PortalCredentials.authenticate(first_token, b.id)
    assert {:ok, _} = PortalCredentials.revoke(admin_scope(a), first)
    assert {:error, :not_found} = PortalCredentials.authenticate(first_token, a.id)
    assert {:ok, %{id: second_id}} = PortalCredentials.authenticate(second_token, a.id)
    assert second_id == second.id
    assert {:error, :not_found} = PortalCredentials.issue(admin_scope(b), org.id)
  end

  test "a forged credential struct cannot revoke another tenant's portal" do
    a = tenant("Alpha")
    b = tenant("Beta")
    org_b = customer(b)
    assert {:ok, credential, token} = PortalCredentials.issue(admin_scope(b), org_b.id)
    forged = %{credential | tenant_id: a.id}
    assert {:error, :not_found} = PortalCredentials.revoke(admin_scope(a), forged)
    assert {:ok, %{id: id}} = PortalCredentials.authenticate(token, b.id)
    assert id == credential.id
  end

  test "agents cannot issue or revoke portal credentials" do
    tenant = tenant("Alpha")
    org = customer(tenant)
    admin = admin_scope(tenant)
    agent = %Custyard.Scope{tenant_id: tenant.id, role: "agent"}
    assert {:error, :unauthorized} = PortalCredentials.issue(agent, org.id)
    assert {:ok, credential, _} = PortalCredentials.issue(admin, org.id)
    assert {:error, :unauthorized} = PortalCredentials.revoke(agent, credential)
  end

  test "demotion invalidates a previously issued administrator scope" do
    tenant = tenant("Alpha")
    org = customer(tenant)
    scope = admin_scope(tenant)
    assert {:ok, credential, token} = PortalCredentials.issue(scope, org.id)
    staff = Repo.get!(Custyard.StaffAccount, scope.staff_id)
    staff |> Ecto.Changeset.change(role: "agent") |> Repo.update!()
    assert {:error, :unauthorized} = PortalCredentials.issue(scope, org.id)
    assert {:error, :unauthorized} = PortalCredentials.revoke(scope, credential)
    assert {:ok, _} = PortalCredentials.authenticate(token, tenant.id)
  end

  test "identical attachments in different tenants have separate files" do
    a = tenant("Alpha")
    b = tenant("Beta")
    ca = insert_thread(tenant_id: a.id, organization_id: customer(a).id)
    cb = insert_thread(tenant_id: b.id, organization_id: customer(b).id)
    ma = insert_message(thread_id: ca.id)
    mb = insert_message(thread_id: cb.id)
    descriptors = [%{content: "shared content", filename: "test.txt"}]
    assert {:ok, [aa]} = Attachments.fetch_for_message(ma, descriptors)
    assert {:ok, [ab]} = Attachments.fetch_for_message(mb, descriptors)
    assert aa.sha256 == ab.sha256
    refute aa.storage_path == ab.storage_path
    assert String.starts_with?(aa.storage_path, "#{a.id}/")
    assert String.starts_with?(ab.storage_path, "#{b.id}/")

    on_exit(fn ->
      File.rm(Attachments.file_path(aa))
      File.rm(Attachments.file_path(ab))
    end)
  end
end
