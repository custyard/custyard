defmodule Custyard.TenantHostRemovalTest do
  use Custyard.DataCase, async: true
  import Custyard.Factory
  alias Custyard.{AuditEvent, Auth.Account, InstanceAdmins, Repo, TenantHost, Tenants}

  setup do
    {:created, admin} = InstanceAdmins.create_admin("host-admin@example.com")
    tenant = insert_tenant()
    {:ok, host} = Tenants.add_host(tenant.id, "primary.example.com")
    %{admin: admin, tenant: tenant, host: host}
  end

  test "the final hostname cannot be removed", c do
    assert {:error, :last_host} = Tenants.remove_host(c.admin, c.tenant.id, c.host.id)
    assert Repo.get(TenantHost, c.host.id)
    assert URI.parse(Tenants.url(c.tenant)).host == c.host.hostname
    refute Repo.get_by(AuditEvent, event_type: :tenant_host_removed)
  end

  test "removing an alternate hostname is audited and preserves a usable URL", c do
    {:ok, alternate} = Tenants.add_host(c.tenant.id, "alternate.example.com")
    assert {:ok, _} = Tenants.remove_host(c.admin, c.tenant.id, c.host.id)
    assert URI.parse(Tenants.url(c.tenant)).host == alternate.hostname
    audit = Repo.get_by!(AuditEvent, event_type: :tenant_host_removed)
    assert audit.tenant_id == c.tenant.id
    assert audit.payload["instance_admin_id"] == c.admin.id
    assert audit.payload["host_id"] == c.host.id
    assert {:error, :last_host} = Tenants.remove_host(c.admin, c.tenant.id, alternate.id)
  end

  test "foreign host IDs and revoked installation sessions cannot remove a hostname", c do
    {:ok, alternate} = Tenants.add_host(c.tenant.id, "alternate.example.com")
    assert {:error, :not_found} = Tenants.remove_host(c.admin, insert_tenant().id, alternate.id)

    Repo.update!(Ecto.Changeset.change(c.admin, session_claim: Account.generate_session_claim()))

    assert {:error, :unauthorized} = Tenants.remove_host(c.admin, c.tenant.id, alternate.id)
    assert Repo.get(TenantHost, alternate.id)
    refute Repo.get_by(AuditEvent, event_type: :tenant_host_removed)
  end

  test "a stale installation-host mapping cannot defeat the last-workspace-host guard", c do
    Repo.insert!(%TenantHost{tenant_id: c.tenant.id, hostname: Tenants.app_host()})
    assert {:error, :last_host} = Tenants.remove_host(c.admin, c.tenant.id, c.host.id)
    assert URI.parse(Tenants.url(c.tenant)).host == c.host.hostname
  end
end
