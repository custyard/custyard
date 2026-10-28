defmodule Custyard.Auth.AccountIdentityTest do
  use Custyard.DataCase, async: true
  import Custyard.Factory
  alias Custyard.{InstanceAdmins, StaffAccount, Repo}

  test "Unicode normalization rejects duplicate staff identity inside a tenant" do
    tenant = insert_tenant()
    insert_staff_account(tenant_id: tenant.id, email: "josé@example.com")

    changeset =
      StaffAccount.changeset(%StaffAccount{}, %{
        tenant_id: tenant.id,
        email: "José@Example.COM",
        role: "agent"
      })

    assert {:error, changeset} = Repo.insert(changeset)
    assert "has already been taken" in errors_on(changeset).email
  end

  test "normalized staff identities are independent between tenants and installation" do
    first = insert_tenant()
    second = insert_tenant()
    one = insert_staff_account(tenant_id: first.id, email: "ÜNAL@BÜCHER.DE")
    two = insert_staff_account(tenant_id: second.id, email: "ünal@bücher.de")
    assert {:created, installation_admin} = InstanceAdmins.create_admin("ÜNAL@BÜCHER.DE")
    assert one.email == two.email
    assert installation_admin.email == one.email
    assert one.tenant_id != two.tenant_id
  end
end
