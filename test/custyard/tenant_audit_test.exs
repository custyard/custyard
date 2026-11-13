defmodule Custyard.TenantAuditTest do
  @moduledoc """
  Creating a tenant, adding a hostname and creating a staff account each
  write an audit record in the same transaction as the change.
  """
  use Custyard.DataCase, async: true

  import Custyard.Factory

  alias Custyard.{
    AuditEvent,
    Auth.Account,
    InstanceAdmins,
    Repo,
    StaffAccount,
    Tenant,
    TenantHost,
    Tenants
  }

  setup do
    {:created, admin} = InstanceAdmins.create_admin("root@install.test")
    tenant = insert_tenant()
    {:ok, _} = Tenants.add_host(tenant.id, "first.example.com")
    manager = insert_staff_account(role: "admin", tenant_id: tenant.id)
    %{admin: admin, tenant: tenant, manager: manager}
  end

  defp events(type),
    do: Repo.all(from e in AuditEvent, where: e.event_type == ^type, order_by: e.id)

  # The account as the caller still holds it, after its session was ended.
  defp revoke(account) do
    Repo.update!(Ecto.Changeset.change(account, session_claim: Account.generate_session_claim()))
    account
  end

  describe "creating a tenant" do
    test "records the instance admin and the first hostname", c do
      assert {:ok, tenant} =
               Tenants.create_tenant_for_admin(c.admin, %{
                 name: "Northwind",
                 slug: "northwind",
                 hostname: "Northwind.Example.com"
               })

      host = Repo.get_by!(TenantHost, tenant_id: tenant.id)

      assert [event] = events(:tenant_created)
      assert event.tenant_id == tenant.id
      assert event.source == "instance_admin"

      assert event.payload == %{
               "instance_admin_id" => c.admin.id,
               "host_id" => host.id,
               "hostname" => "northwind.example.com"
             }

      # The first hostname is part of the creation, not a second event.
      assert events(:tenant_host_added) == []
    end

    test "records nothing when the tenant is not created", c do
      assert {:error, %Ecto.Changeset{}} =
               Tenants.create_tenant_for_admin(c.admin, %{
                 name: "Taken host",
                 slug: "taken-host",
                 hostname: "first.example.com"
               })

      assert {:error, %Ecto.Changeset{}} =
               Tenants.create_tenant_for_admin(c.admin, %{
                 name: "Reserved",
                 slug: "reserved",
                 hostname: Tenants.app_host()
               })

      assert {:error, %Ecto.Changeset{}} =
               Tenants.create_tenant_for_admin(c.admin, %{
                 name: "Same slug",
                 slug: c.tenant.slug,
                 hostname: "same-slug.example.com"
               })

      assert {:error, :unauthorized} =
               Tenants.create_tenant_for_admin(revoke(c.admin), %{
                 name: "Revoked",
                 slug: "revoked",
                 hostname: "revoked.example.com"
               })

      assert Repo.aggregate(Tenant, :count) == 1
      assert events(:tenant_created) == []
    end
  end

  describe "adding a hostname" do
    test "records the instance admin and the hostname", c do
      assert {:ok, host} =
               Tenants.add_host_for_admin(c.admin, c.tenant.id, "Second.Example.com.")

      assert [event] = events(:tenant_host_added)
      assert event.tenant_id == c.tenant.id
      assert event.source == "instance_admin"

      assert event.payload == %{
               "instance_admin_id" => c.admin.id,
               "host_id" => host.id,
               "hostname" => "second.example.com"
             }
    end

    test "records nothing when the hostname is not added", c do
      assert {:error, %Ecto.Changeset{}} =
               Tenants.add_host_for_admin(c.admin, c.tenant.id, "first.example.com")

      assert {:error, %Ecto.Changeset{}} =
               Tenants.add_host_for_admin(c.admin, c.tenant.id, "not a hostname")

      assert {:error, :unauthorized} =
               Tenants.add_host_for_admin(revoke(c.admin), c.tenant.id, "second.example.com")

      assert Repo.aggregate(TenantHost, :count) == 1
      assert events(:tenant_host_added) == []
    end
  end

  describe "creating a staff account" do
    test "records the instance admin who provisioned it", c do
      assert {:ok, staff} =
               Tenants.provision_staff(c.admin, c.tenant.id, %{
                 "email" => "hank@northwind.test",
                 "role" => "agent"
               })

      assert [event] = events(:staff_created)
      assert event.tenant_id == c.tenant.id
      assert event.source == "instance_admin"

      assert event.payload == %{
               "staff_id" => staff.id,
               "instance_admin_id" => c.admin.id,
               "role" => "agent",
               "via" => "instance_admin"
             }
    end

    test "records the tenant admin who invited it", c do
      assert {:ok, staff} =
               Tenants.invite_staff(c.manager, c.tenant.id, %{
                 email: "ivy@northwind.test",
                 role: "admin"
               })

      assert [event] = events(:staff_created)
      assert event.tenant_id == c.tenant.id
      assert event.source == "staff"

      assert event.payload == %{
               "staff_id" => staff.id,
               "actor_staff_id" => c.manager.id,
               "role" => "admin",
               "via" => "staff"
             }
    end

    test "records nothing when the account is not created", c do
      agent = insert_staff_account(role: "agent", tenant_id: c.tenant.id)

      assert {:error, %Ecto.Changeset{}} =
               Tenants.provision_staff(c.admin, c.tenant.id, %{email: "nope", role: "admin"})

      assert {:error, %Ecto.Changeset{}} =
               Tenants.invite_staff(c.manager, c.tenant.id, %{
                 email: c.manager.email,
                 role: "agent"
               })

      assert {:error, :unauthorized} =
               Tenants.invite_staff(agent, c.tenant.id, %{
                 email: "by-agent@northwind.test",
                 role: "agent"
               })

      assert {:error, :unauthorized} =
               Tenants.provision_staff(revoke(c.admin), c.tenant.id, %{
                 email: "by-revoked@northwind.test",
                 role: "admin"
               })

      assert Repo.aggregate(StaffAccount, :count) == 2
      assert events(:staff_created) == []
    end
  end
end
