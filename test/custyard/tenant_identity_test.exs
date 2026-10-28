defmodule Custyard.TenantIdentityTest do
  use Custyard.DataCase

  alias Custyard.{
    Auth.Account,
    InstanceAdmin,
    InstanceAdmins,
    StaffAccount,
    Scope,
    Tenant,
    Tenants
  }

  test "staff email belongs to a tenant and grants no installation authority" do
    {:ok, first} = Tenants.create_tenant(%{name: "First", slug: "first"})
    {:ok, second} = Tenants.create_tenant(%{name: "Second", slug: "second"})

    {:ok, staff} =
      %StaffAccount{}
      |> StaffAccount.changeset(%{
        tenant_id: first.id,
        email: "PERSON@EXAMPLE.COM",
        role: "admin"
      })
      |> Repo.insert()

    assert {:ok, _} =
             %StaffAccount{}
             |> StaffAccount.changeset(%{
               tenant_id: second.id,
               email: "person@example.com",
               role: "agent"
             })
             |> Repo.insert()

    assert %Scope{tenant_id: id} = Scope.for_staff(staff, first)
    assert id == first.id
    assert is_nil(Scope.for_staff(staff, second))
    assert is_nil(Scope.for_staff(%InstanceAdmin{}, first))

    refute StaffAccount.changeset(%StaffAccount{}, %{
             email: "staff@example.com",
             role: "super_admin"
           }).valid?
  end

  test "installation host is reserved while hostname uniqueness covers all tenants" do
    {:ok, first} = Tenants.create_tenant(%{name: "First", slug: "first"})
    {:ok, second} = Tenants.create_tenant(%{name: "Second", slug: "second"})
    assert is_nil(Tenants.resolve_host(Tenants.app_host()))
    assert {:error, changeset} = Tenants.add_host(first.id, Tenants.app_host())
    assert "is reserved for the installation" in errors_on(changeset).hostname
    assert {:error, _} = Tenants.add_host(second.id, String.upcase(Tenants.app_host()))
    assert is_nil(Tenants.resolve_host("unregistered.example.com"))
    assert {:ok, _} = Tenants.add_host(second.id, "Support.Example.com.")
    assert Tenants.resolve_host("SUPPORT.EXAMPLE.COM").id == second.id
    assert {:error, _} = Tenants.add_host(first.id, "support.example.com")
  end

  test "a stale installation hostname mapping cannot establish a tenant scope" do
    {:ok, tenant} = Tenants.create_tenant(%{name: "First", slug: "first"})

    Repo.insert!(%Custyard.TenantHost{tenant_id: tenant.id, hostname: Tenants.app_host()})

    assert is_nil(Tenants.resolve_host(Tenants.app_host()))
    assert is_nil(Tenants.resolve_host(String.upcase(Tenants.app_host()) <> "."))
    assert is_nil(Tenants.host(tenant))

    assert {:ok, _} = Tenants.add_host(tenant.id, "workspace.example.com")
    assert Tenants.host(tenant) == "workspace.example.com"
    assert URI.parse(Tenants.url(tenant)).host == "workspace.example.com"
  end

  test "suspension rejects staff scope and requires an installation identity" do
    {:created, admin} = InstanceAdmins.create_admin("instance@example.com")
    {:ok, tenant} = Tenants.create_tenant(%{name: "Workspace", slug: "workspace"})

    {:ok, staff} =
      Tenants.provision_staff(admin, tenant.id, %{email: "staff@example.com", role: "admin"})

    assert {:ok, %Tenant{status: "suspended"} = suspended} =
             Tenants.set_status(admin, tenant.id, "suspended")

    refute Tenants.staff_on_host?(staff, tenant.id)
    assert is_nil(Scope.for_staff(staff, suspended))
    assert Tenant.changeset(tenant, %{status: "active"}).valid?
    refute Tenant.changeset(tenant, %{status: "unknown"}).valid?
    assert {:ok, _} = Tenants.set_status(admin, tenant.id, "active")
    assert Tenants.staff_on_host?(staff, tenant.id)
  end

  test "shared login primitive consumes a link only once and claims distinguish accounts" do
    {:created, admin} = InstanceAdmins.create_admin("instance@example.com")
    tokenized = Account.ensure_login_token(admin)
    assert Account.login_token_valid?(tokenized)
    assert :ok = Account.consume_login_token(tokenized, tokenized.login_token)
    assert {:error, :invalid} = Account.consume_login_token(tokenized, tokenized.login_token)
    refute Account.session_claim_matches?(admin, Account.generate_session_claim())
  end
end
