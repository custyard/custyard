defmodule Custyard.TenantStaffAuthorizationTest do
  use Custyard.DataCase, async: true

  alias Custyard.{StaffAccount, Repo, Tenants}

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

  test "staff provisioning and removal emit typed events without addresses", c do
    import ExUnit.CaptureLog

    Logger.put_module_level(Tenants, :info)
    on_exit(fn -> Logger.delete_module_level(Tenants) end)

    {invited, created_log} =
      with_log([metadata: [:staff_id, :tenant_id, :role]], fn ->
        assert {:ok, invited} =
                 Tenants.invite_staff(c.admin, c.tenant.id, %{
                   "email" => "logged@invited.example",
                   "role" => "agent"
                 })

        invited
      end)

    assert created_log =~ "staff_account_created"
    assert created_log =~ "staff_id=#{invited.id}"
    assert created_log =~ "tenant_id=#{c.tenant.id}"
    assert created_log =~ "role=agent"
    refute created_log =~ "logged@invited.example"

    removed_log =
      capture_log([metadata: [:staff_id, :tenant_id, :role]], fn ->
        assert {:ok, _} = Tenants.remove_staff(c.admin, c.tenant.id, invited.id)
      end)

    assert removed_log =~ "staff_account_removed"
    assert removed_log =~ "staff_id=#{invited.id}"
    refute removed_log =~ "logged@invited.example"

    rejected_log =
      capture_log(fn ->
        assert {:error, _} =
                 Tenants.invite_staff(c.admin, c.tenant.id, %{email: "nope", role: "agent"})

        assert {:error, :not_found} = Tenants.remove_staff(c.admin, c.tenant.id, invited.id)
      end)

    refute rejected_log =~ "staff_account_"
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
      assert invited.role == role
    end

    for role <- ["super_admin", nil] do
      assert {:error, %Ecto.Changeset{}} =
               Tenants.invite_staff(c.admin, c.tenant.id, %{
                 email: "forged@example.net",
                 role: role
               })
    end

    refute Repo.get_by(StaffAccount, email: "forged@example.net")

    assert {:ok, updated} =
             Tenants.update_tenant_for_staff(c.admin, c.tenant.id, %{name: "Updated"})

    assert updated.name == "Updated"
  end

  test "foreign scope and forged in-memory roles cannot authorize writes", c do
    assert_unauthorized(c.admin, c.other)
    assert_unauthorized(%{c.agent | role: "super_admin"}, c.tenant)
  end

  test "administrator demotion after an event refresh prevents both writes", c do
    c.admin |> StaffAccount.role_changeset(%{role: "agent"}) |> Repo.update!()
    assert_unauthorized(c.admin, c.tenant)
  end

  test "session revocation after an event refresh prevents both writes", c do
    c.admin
    |> Ecto.Changeset.change(session_claim: StaffAccount.generate_session_claim())
    |> Repo.update!()

    assert_unauthorized(c.admin, c.tenant)
  end

  test "administrator reassignment after an event refresh prevents writes to the previous tenant",
       c do
    c.admin |> Ecto.Changeset.change(tenant_id: c.other.id) |> Repo.update!()
    assert_unauthorized(c.admin, c.tenant)
  end

  test "administrator removal after an event refresh prevents both writes", c do
    Repo.delete!(c.admin)
    assert_unauthorized(c.admin, c.tenant)
  end

  test "creating tenants rechecks the installation administrator claim" do
    {:created, admin} = Custyard.InstanceAdmins.create_admin("instance@example.com")

    assert {:ok, _} =
             Tenants.create_tenant_for_admin(admin, %{
               name: "New",
               slug: "created",
               hostname: "created.example.com"
             })

    admin
    |> Ecto.Changeset.change(session_claim: StaffAccount.generate_session_claim())
    |> Repo.update!()

    assert {:error, :unauthorized} =
             Tenants.create_tenant_for_admin(admin, %{
               name: "Revoked",
               slug: "revoked",
               hostname: "revoked.example.com"
             })

    refute Repo.get_by(Custyard.Tenant, slug: "revoked")
  end

  defp assert_unauthorized(staff, tenant) do
    assert {:error, :unauthorized} =
             Tenants.invite_staff(staff, tenant.id, %{
               email: "unauthorized@example.net",
               role: "admin"
             })

    assert {:error, :unauthorized} =
             Tenants.update_tenant_for_staff(staff, tenant.id, %{name: "Unauthorized"})

    refute Repo.get_by(StaffAccount, email: "unauthorized@example.net")
    assert Repo.reload!(tenant).name == tenant.name
  end

  defp staff(tenant, role) do
    %StaffAccount{}
    |> StaffAccount.changeset(%{
      email: "#{role}-#{System.unique_integer([:positive])}@staff.example",
      role: role,
      tenant_id: tenant.id
    })
    |> Repo.insert!()
  end
end
