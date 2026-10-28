defmodule Custyard.LabelsTest do
  use Custyard.DataCase, async: true
  import Custyard.Factory
  alias Custyard.{Threads, Labels, Scope, Tenants}

  defp scope(staff), do: Scope.for_staff(staff, Tenants.get_tenant!(staff.tenant_id))

  setup do
    {:ok, tenant} =
      Tenants.create_tenant(%{
        name: "Labels",
        slug: "labels-#{System.unique_integer([:positive])}"
      })

    {:ok, other} =
      Tenants.create_tenant(%{name: "Other", slug: "other-#{System.unique_integer([:positive])}"})

    org = insert_organization(tenant_id: tenant.id)
    other_org = insert_organization(tenant_id: other.id)

    staff =
      insert_staff_account(role: "admin", organization_id: org.id, tenant_id: tenant.id)

    thread = insert_thread(organization_id: org.id)

    %{
      tenant: tenant,
      other_org: other_org,
      org: org,
      staff: staff,
      thread: thread
    }
  end

  test "labels are reusable within a tenant and assignments are idempotent", c do
    assert {:ok, label} = Labels.create_and_assign(scope(c.staff), c.thread, " Billing ")
    assert label.name == "Billing"
    assert {:ok, _} = Labels.assign(scope(c.staff), c.thread, label.id)
    assert %{assigned: [^label]} = Labels.for_thread(scope(c.staff), c.thread)

    assert {:error, changeset} =
             Labels.create_and_assign(scope(c.staff), c.thread, "billing")

    assert "has already been taken" in errors_on(changeset).tenant_id
    assert {:ok, :removed} = Labels.remove(scope(c.staff), c.thread, label.id)

    assert %{assigned: [], available: [^label]} =
             Labels.for_thread(scope(c.staff), c.thread)
  end

  test "foreign labels cannot be read, assigned or used to cross tenant boundaries", c do
    foreign_staff =
      insert_staff_account(
        role: "admin",
        organization_id: c.other_org.id,
        tenant_id: c.other_org.tenant_id
      )

    foreign_thread = insert_thread(organization_id: c.other_org.id)

    {:ok, label} =
      Labels.create_and_assign(scope(foreign_staff), foreign_thread, "Private")

    refute label in Labels.list(scope(c.staff))

    assert %{available: [], assigned: []} =
             Labels.for_thread(scope(c.staff), foreign_thread)

    assert {:error, :not_found} = Labels.assign(scope(c.staff), c.thread, label.id)

    assert {:error, :unauthorized} =
             Labels.assign(scope(c.staff), foreign_thread, label.id)

    assert Threads.list(scope(c.staff), organization_id: c.org.id, label_id: label.id) ==
             []
  end

  test "agents can apply existing labels but cannot define labels", c do
    {:ok, label} = Labels.create_and_assign(scope(c.staff), c.thread, "Bug")
    {:ok, _} = Labels.remove(scope(c.staff), c.thread, label.id)

    agent =
      insert_staff_account(role: "agent", organization_id: c.org.id, tenant_id: c.tenant.id)

    assert {:ok, _} = Labels.assign(scope(agent), c.thread, label.id)
    assert {:error, :unauthorized} = Labels.create_and_assign(scope(agent), c.thread, "New")
  end

  test "unlinked public threads use their workspace labels", c do
    thread = insert_thread(source: :public_intake, tenant_id: c.tenant.id)
    assert is_nil(thread.organization_id)

    assert {:ok, label} =
             Labels.create_and_assign(scope(c.staff), thread, "Public question")

    assert %{assigned: [^label]} = Labels.for_thread(scope(c.staff), thread)
    id = thread.id
    assert %{^id => [^label]} = Labels.for_threads([thread])

    assert [%{thread: %{id: ^id}}] =
             Threads.list(scope(c.staff), label_id: label.id)
  end

  test "tenant staff can filter with their workspace labels only", c do
    {:ok, label} = Labels.create_and_assign(scope(c.staff), c.thread, "Customer request")

    for role <- ["admin", "agent"] do
      staff = insert_staff_account(role: role, tenant_id: c.tenant.id)
      assert Labels.list(scope(staff)) == [label]
      assert Labels.list(scope(staff)) == [label]
      assert Labels.list(%{scope(staff) | tenant_id: c.other_org.tenant_id}) == []
      assert %{available: [^label]} = Labels.for_thread(scope(staff), c.thread)
    end

    assert Labels.list(nil) == []
    assert Labels.list(nil) == []
  end
end
