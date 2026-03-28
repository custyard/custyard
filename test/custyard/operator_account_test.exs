defmodule Custyard.OperatorAccountTest do
  use Custyard.DataCase, async: true

  alias Custyard.OperatorAccount
  alias Custyard.Factory

  describe "changeset/2" do
    test "validates required fields" do
      changeset = OperatorAccount.changeset(%OperatorAccount{}, %{})

      assert %{email: ["can't be blank"], password: ["can't be blank"]} = errors_on(changeset)
    end

    test "validates email format" do
      attrs = Factory.build_operator_account(email: "invalid")
      changeset = OperatorAccount.changeset(%OperatorAccount{}, attrs)

      assert %{email: ["must be a valid email address"]} = errors_on(changeset)
    end

    test "validates password length" do
      attrs = Factory.build_operator_account(password: "short")
      changeset = OperatorAccount.changeset(%OperatorAccount{}, attrs)

      assert %{password: ["must be between 8 and 72 characters"]} = errors_on(changeset)
    end

    test "validates role must be valid" do
      attrs = Factory.build_operator_account(role: "invalid_role")
      changeset = OperatorAccount.changeset(%OperatorAccount{}, attrs)

      assert %{role: ["must be one of: super_admin, admin, agent"]} = errors_on(changeset)
    end

    test "accepts valid roles" do
      for role <- ~w(super_admin admin agent) do
        org = if role != "super_admin", do: Factory.insert_organization(), else: nil
        org_id = if org, do: org.id, else: nil

        attrs = Factory.build_operator_account(role: role, organization_id: org_id)
        changeset = OperatorAccount.changeset(%OperatorAccount{}, attrs)

        assert changeset.valid?,
               "Role #{role} should be valid, errors: #{inspect(errors_on(changeset))}"
      end
    end

    test "super_admin cannot have organization_id" do
      org = Factory.insert_organization()
      attrs = Factory.build_operator_account(role: "super_admin", organization_id: org.id)
      changeset = OperatorAccount.changeset(%OperatorAccount{}, attrs)

      assert %{organization_id: ["super_admin operators cannot be scoped to an organization"]} =
               errors_on(changeset)
    end

    test "admin requires organization_id" do
      attrs = Factory.build_operator_account(role: "admin", organization_id: nil)
      changeset = OperatorAccount.changeset(%OperatorAccount{}, attrs)

      assert %{organization_id: ["admin operators must be assigned to an organization"]} =
               errors_on(changeset)
    end

    test "agent requires organization_id" do
      attrs = Factory.build_operator_account(role: "agent", organization_id: nil)
      changeset = OperatorAccount.changeset(%OperatorAccount{}, attrs)

      assert %{organization_id: ["agent operators must be assigned to an organization"]} =
               errors_on(changeset)
    end

    test "hashes password" do
      attrs = Factory.build_operator_account()
      changeset = OperatorAccount.changeset(%OperatorAccount{}, attrs)

      assert changeset.changes[:password_hash]
      refute changeset.changes[:password_hash] == attrs.password
    end
  end

  describe "role_changeset/2" do
    test "allows changing role from super_admin to admin with organization" do
      operator = Factory.insert_operator_account(role: "super_admin")
      org = Factory.insert_organization()

      changeset =
        OperatorAccount.role_changeset(operator, %{role: "admin", organization_id: org.id})

      assert changeset.valid?
    end

    test "prevents changing to admin without organization" do
      operator = Factory.insert_operator_account(role: "super_admin")

      changeset = OperatorAccount.role_changeset(operator, %{role: "admin"})

      assert %{organization_id: ["admin operators must be assigned to an organization"]} =
               errors_on(changeset)
    end

    test "prevents changing to super_admin with organization" do
      operator = Factory.insert_operator_account(role: "admin")

      changeset = OperatorAccount.role_changeset(operator, %{role: "super_admin"})

      # The org_id from the existing operator will still be there
      assert %{organization_id: ["super_admin operators cannot be scoped to an organization"]} =
               errors_on(changeset)
    end

    test "allows changing from admin to super_admin by clearing organization_id" do
      operator = Factory.insert_operator_account(role: "admin")

      changeset =
        OperatorAccount.role_changeset(operator, %{role: "super_admin", organization_id: nil})

      assert changeset.valid?
    end
  end

  describe "password_changeset/2" do
    test "updates password and rehashes" do
      operator = Factory.insert_operator_account()
      old_hash = operator.password_hash

      changeset = OperatorAccount.password_changeset(operator, %{password: "newpassword123"})

      assert changeset.valid?
      assert changeset.changes[:password_hash]
      refute changeset.changes[:password_hash] == old_hash
    end

    test "validates password length" do
      operator = Factory.insert_operator_account()

      changeset = OperatorAccount.password_changeset(operator, %{password: "short"})

      assert %{password: ["must be between 8 and 72 characters"]} = errors_on(changeset)
    end
  end

  describe "verify_password/2" do
    test "returns true for correct password" do
      operator = Factory.insert_operator_account(password: "testpassword123")

      assert OperatorAccount.verify_password(operator, "testpassword123")
    end

    test "returns false for incorrect password" do
      operator = Factory.insert_operator_account(password: "testpassword123")

      refute OperatorAccount.verify_password(operator, "wrongpassword")
    end

    test "returns false for nil operator (timing attack protection)" do
      refute OperatorAccount.verify_password(nil, "anypassword")
    end

    test "returns false for non-operator struct" do
      refute OperatorAccount.verify_password(%{}, "anypassword")
    end
  end

  describe "super_admin?/1" do
    test "returns true for super_admin role" do
      operator = Factory.insert_operator_account(role: "super_admin")

      assert OperatorAccount.super_admin?(operator)
    end

    test "returns false for admin role" do
      operator = Factory.insert_operator_account(role: "admin")

      refute OperatorAccount.super_admin?(operator)
    end

    test "returns false for agent role" do
      operator = Factory.insert_operator_account(role: "agent")

      refute OperatorAccount.super_admin?(operator)
    end

    test "returns false for nil" do
      refute OperatorAccount.super_admin?(nil)
    end
  end

  describe "can_access_organization?/2" do
    test "super_admin can access any organization" do
      operator = Factory.insert_operator_account(role: "super_admin")
      org = Factory.insert_organization()

      assert OperatorAccount.can_access_organization?(operator, org.id)
    end

    test "super_admin can access nil organization" do
      operator = Factory.insert_operator_account(role: "super_admin")

      # Returns true because super_admin pattern matches first
      assert OperatorAccount.can_access_organization?(operator, nil)
    end

    test "admin can access their own organization" do
      org = Factory.insert_organization()
      operator = Factory.insert_operator_account(role: "admin", organization_id: org.id)

      assert OperatorAccount.can_access_organization?(operator, org.id)
    end

    test "admin cannot access other organizations" do
      org1 = Factory.insert_organization()
      org2 = Factory.insert_organization()
      operator = Factory.insert_operator_account(role: "admin", organization_id: org1.id)

      refute OperatorAccount.can_access_organization?(operator, org2.id)
    end

    test "agent can access their own organization" do
      org = Factory.insert_organization()
      operator = Factory.insert_operator_account(role: "agent", organization_id: org.id)

      assert OperatorAccount.can_access_organization?(operator, org.id)
    end

    test "agent cannot access other organizations" do
      org1 = Factory.insert_organization()
      org2 = Factory.insert_organization()
      operator = Factory.insert_operator_account(role: "agent", organization_id: org1.id)

      refute OperatorAccount.can_access_organization?(operator, org2.id)
    end

    test "returns false for nil operator" do
      refute OperatorAccount.can_access_organization?(nil, 1)
    end

    test "returns false for non-integer org_id with non-super_admin" do
      org = Factory.insert_organization()
      operator = Factory.insert_operator_account(role: "admin", organization_id: org.id)

      refute OperatorAccount.can_access_organization?(operator, "not-an-integer")
    end
  end

  describe "scoped_organization_id/1" do
    test "returns nil for super_admin" do
      operator = Factory.insert_operator_account(role: "super_admin")

      assert is_nil(OperatorAccount.scoped_organization_id(operator))
    end

    test "returns organization_id for admin" do
      org = Factory.insert_organization()
      operator = Factory.insert_operator_account(role: "admin", organization_id: org.id)

      assert OperatorAccount.scoped_organization_id(operator) == org.id
    end

    test "returns organization_id for agent" do
      org = Factory.insert_organization()
      operator = Factory.insert_operator_account(role: "agent", organization_id: org.id)

      assert OperatorAccount.scoped_organization_id(operator) == org.id
    end

    test "returns nil for nil input" do
      assert is_nil(OperatorAccount.scoped_organization_id(nil))
    end
  end

  describe "roles/0" do
    test "returns list of valid roles" do
      assert OperatorAccount.roles() == ~w(super_admin admin agent)
    end
  end
end
