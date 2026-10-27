defmodule Custyard.TenantStaffAuthorizationTest do
  use Custyard.DataCase, async: true

  alias Custyard.{OperatorAccount, Repo, Tenants}

  setup do
    {:ok, tenant} =
      Tenants.create_tenant(%{
        name: "Managed",
        slug: "managed-#{System.unique_integer([:positive])}"
      })

    {:ok, other} =
      Tenants.create_tenant(%{name: "Other", slug: "other-#{System.unique_integer([:positive])}"})

    admin = staff(tenant, "admin")
    agent = staff(tenant, "agent")
    %{tenant: tenant, other: other, admin: admin, agent: agent}
  end

  test "tenant administrators invite only tenant staff and update their current tenant", c do
    for role <- ["admin", "agent"] do
      assert {:ok, invited} =
               Tenants.invite_staff(c.admin, c.tenant.id, %{
                 "email" => "#{role}@invited.example",
                 "role" => role,
                 "tenant_id" => c.other.id,
                 "organization_id" => 999_999
               })

      assert invited.tenant_id == c.tenant.id
      assert invited.organization_id == nil
      assert invited.role == role
    end

    for role <- ["super_admin", nil] do
      assert {:error, %Ecto.Changeset{}} =
               Tenants.invite_staff(c.admin, c.tenant.id, %{
                 email: "forged@example.net",
                 role: role
               })
    end

    refute Repo.get_by(OperatorAccount, email: "forged@example.net")

    assert {:ok, updated} =
             Tenants.update_tenant_for_operator(c.admin, c.tenant.id, %{name: "Updated"})

    assert updated.name == "Updated"
  end

  test "foreign scope and forged in-memory roles cannot authorize writes", c do
    assert_unauthorized(c.admin, c.other)
    assert_unauthorized(%{c.agent | role: "super_admin"}, c.tenant)
  end

  test "administrator demotion after an event refresh prevents both writes", c do
    c.admin |> OperatorAccount.role_changeset(%{role: "agent"}) |> Repo.update!()
    assert_unauthorized(c.admin, c.tenant)
  end

  test "session revocation after an event refresh prevents both writes", c do
    c.admin
    |> Ecto.Changeset.change(session_claim: OperatorAccount.generate_session_claim())
    |> Repo.update!()

    assert_unauthorized(c.admin, c.tenant)
  end

  test "administrator reassignment after an event refresh prevents writes to the previous tenant",
       c do
    c.admin |> OperatorAccount.role_changeset(%{tenant_id: c.other.id}) |> Repo.update!()
    assert_unauthorized(c.admin, c.tenant)
  end

  test "administrator removal after an event refresh prevents both writes", c do
    Repo.delete!(c.admin)
    assert_unauthorized(c.admin, c.tenant)
  end

  test "creating tenants rechecks the current instance administrator and session", c do
    operator =
      %OperatorAccount{}
      |> OperatorAccount.changeset(%{email: "instance@managed.example", role: "super_admin"})
      |> Repo.insert!()

    assert {:ok, _} =
             Tenants.create_tenant_for_operator(operator, %{
               name: "New tenant",
               slug: "created-by-instance"
             })

    assert {:error, :unauthorized} =
             Tenants.create_tenant_for_operator(%{c.agent | role: "super_admin"}, %{
               name: "Forged tenant",
               slug: "forged-by-instance"
             })

    operator
    |> Ecto.Changeset.change(session_claim: OperatorAccount.generate_session_claim())
    |> Repo.update!()

    assert {:error, :unauthorized} =
             Tenants.create_tenant_for_operator(operator, %{
               name: "Revoked tenant",
               slug: "revoked-by-instance"
             })

    refute Repo.get_by(Custyard.Tenant, slug: "forged-by-instance")
    refute Repo.get_by(Custyard.Tenant, slug: "revoked-by-instance")
  end

  defp assert_unauthorized(operator, tenant) do
    assert {:error, :unauthorized} =
             Tenants.invite_staff(operator, tenant.id, %{
               email: "unauthorized@example.net",
               role: "admin"
             })

    assert {:error, :unauthorized} =
             Tenants.update_tenant_for_operator(operator, tenant.id, %{name: "Unauthorized"})

    refute Repo.get_by(OperatorAccount, email: "unauthorized@example.net")
    assert Repo.reload!(tenant).name == tenant.name
  end

  defp staff(tenant, role) do
    %OperatorAccount{}
    |> OperatorAccount.changeset(%{
      email: "#{role}-#{System.unique_integer([:positive])}@staff.example",
      role: role,
      tenant_id: tenant.id
    })
    |> Repo.insert!()
  end
end
