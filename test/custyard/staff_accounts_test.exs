defmodule Custyard.StaffAccountsTest do
  use Custyard.DataCase
  alias Custyard.{Factory, StaffAccount, StaffAccounts, Repo}

  test "creation and lookup are tenant scoped and never modify existing staff" do
    one = Factory.insert_tenant()
    two = Factory.insert_tenant()

    assert {:created, staff} =
             StaffAccounts.create_staff("USER@EXAMPLE.COM",
               tenant_id: one.id,
               role: "admin"
             )

    assert {:exists, same} =
             StaffAccounts.create_staff("user@example.com",
               tenant_id: one.id,
               role: "agent"
             )

    assert same.id == staff.id
    assert same.role == "admin"

    assert {:created, foreign} =
             StaffAccounts.create_staff("user@example.com",
               tenant_id: two.id,
               role: "agent"
             )

    assert foreign.id != staff.id
    assert StaffAccounts.get_by_email(one.id, "USER@example.com").id == staff.id
    assert Enum.map(StaffAccounts.list_staff(one.id), & &1.id) == [staff.id]
    assert {:ok, _} = StaffAccounts.remove_staff(two.id, foreign.email)
    assert Repo.get(StaffAccount, staff.id)
    refute Repo.get(StaffAccount, foreign.id)
  end

  test "instance roles and missing ownership cannot be inserted" do
    one = Factory.insert_tenant()

    assert {:error, _} =
             StaffAccounts.create_staff("bad@example.com",
               tenant_id: one.id,
               role: "super_admin"
             )

    assert {:error, _} =
             StaffAccounts.create_staff("bad@example.com", tenant_id: nil, role: "admin")
  end
end
