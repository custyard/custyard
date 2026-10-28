defmodule Custyard.OperatorAccountsTest do
  use Custyard.DataCase
  alias Custyard.{Factory, OperatorAccount, OperatorAccounts, Repo}

  test "creation and lookup are tenant scoped and never modify existing staff" do
    one = Factory.insert_tenant()
    two = Factory.insert_tenant()

    assert {:created, staff} =
             OperatorAccounts.create_operator("USER@EXAMPLE.COM",
               tenant_id: one.id,
               role: "admin"
             )

    assert {:exists, same} =
             OperatorAccounts.create_operator("user@example.com",
               tenant_id: one.id,
               role: "agent"
             )

    assert same.id == staff.id
    assert same.role == "admin"

    assert {:created, foreign} =
             OperatorAccounts.create_operator("user@example.com",
               tenant_id: two.id,
               role: "agent"
             )

    assert foreign.id != staff.id
    assert OperatorAccounts.get_by_email(one.id, "USER@example.com").id == staff.id
    assert Enum.map(OperatorAccounts.list_operators(one.id), & &1.id) == [staff.id]
    assert {:ok, _} = OperatorAccounts.remove_operator(two.id, foreign.email)
    assert Repo.get(OperatorAccount, staff.id)
    refute Repo.get(OperatorAccount, foreign.id)
  end

  test "instance roles and missing ownership cannot be inserted" do
    one = Factory.insert_tenant()

    assert {:error, _} =
             OperatorAccounts.create_operator("bad@example.com",
               tenant_id: one.id,
               role: "super_admin"
             )

    assert {:error, _} =
             OperatorAccounts.create_operator("bad@example.com", tenant_id: nil, role: "admin")
  end
end
