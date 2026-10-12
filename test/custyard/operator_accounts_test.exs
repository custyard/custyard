defmodule Custyard.OperatorAccountsTest do
  use Custyard.DataCase, async: true

  alias Custyard.{OperatorAccount, OperatorAccounts}

  describe "ensure_exists/1" do
    test "creates a super_admin with the normalized email" do
      assert OperatorAccounts.ensure_exists(" Ops@Example.COM ") == {:ok, :created}

      assert [%OperatorAccount{email: "ops@example.com", role: "super_admin"}] =
               Repo.all(OperatorAccount)
    end

    test "is a no-op when the email exists in any letter case" do
      assert OperatorAccounts.ensure_exists("ünal@bücher.de") == {:ok, :created}
      assert OperatorAccounts.ensure_exists("ÜNAL@BÜCHER.DE") == {:ok, :exists}

      assert [%OperatorAccount{email: "ünal@bücher.de"}] = Repo.all(OperatorAccount)
    end

    test "returns the changeset for an invalid email" do
      assert {:error, changeset} = OperatorAccounts.ensure_exists("not-an-email")
      assert %{email: ["must be a valid email address"]} = errors_on(changeset)
      assert Repo.all(OperatorAccount) == []
    end
  end
end
