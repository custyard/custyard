defmodule Custyard.OperatorAccountTest do
  use Custyard.DataCase, async: true
  alias Custyard.{Factory, OperatorAccount}

  test "staff requires a tenant, valid normalized email and tenant role" do
    changeset = OperatorAccount.changeset(%OperatorAccount{}, %{})
    assert errors_on(changeset).email == ["can't be blank"]
    assert errors_on(changeset).tenant_id == ["can't be blank"]
    tenant = Factory.insert_tenant()
    attrs = %{tenant_id: tenant.id, email: "  Ops@Example.COM  ", role: "admin"}

    assert %{valid?: true, changes: %{email: "ops@example.com"}} =
             OperatorAccount.changeset(%OperatorAccount{}, attrs)

    for role <- ~w(super_admin owner unknown) do
      refute OperatorAccount.changeset(%OperatorAccount{}, Map.put(attrs, :role, role)).valid?
    end

    for email <- [
          "invalid",
          "x y@example.com",
          "ops\u00A0team@example.com",
          <<0xFF>> <> "@example.com"
        ] do
      assert errors_on(
               OperatorAccount.changeset(%OperatorAccount{}, Map.put(attrs, :email, email))
             ).email == ["must be a valid email address"]
    end
  end

  test "role changes cannot reassign ownership or grant installation access" do
    staff = Factory.insert_operator_account(role: "admin")
    other = Factory.insert_tenant()

    changeset =
      OperatorAccount.role_changeset(staff, %{
        role: "agent",
        tenant_id: other.id,
        organization_id: 999
      })

    assert changeset.valid?
    assert changeset.changes == %{role: "agent"}
    refute OperatorAccount.role_changeset(staff, %{role: "super_admin"}).valid?
    assert OperatorAccount.roles() == ~w(admin agent)
  end

  describe "normalize_email/1" do
    test "is idempotent" do
      for email <- [
            " Ops@Example.COM ",
            "ÜNAL@BÜCHER.DE",
            "Jose\u0301@Example.com",
            "İstanbul@Example.TR",
            "ΣΟΦΙΑ@Example.GR",
            "\u00A0ops@example.com\u3000"
          ] do
        once = OperatorAccount.normalize_email(email)
        assert OperatorAccount.normalize_email(once) == once
      end
    end

    test "trims non-ASCII whitespace at the ends" do
      assert OperatorAccount.normalize_email("\u00A0Ops@Example.com\u3000") == "ops@example.com"
    end

    test "returns invalid UTF-8 unchanged" do
      bad = <<0xFF>> <> " Ops@Example.com"
      assert OperatorAccount.normalize_email(bad) == bad
    end

    test "trims and lowercases" do
      assert OperatorAccount.normalize_email("  Ops@Example.COM \n") == "ops@example.com"
    end

    test "lowercases beyond ASCII" do
      assert OperatorAccount.normalize_email("ÉLODIE@Exemple.FR") == "élodie@exemple.fr"
    end

    test "leaves a normalized email unchanged" do
      assert OperatorAccount.normalize_email("ops@example.com") == "ops@example.com"
    end

    test "is nil-safe" do
      assert OperatorAccount.normalize_email(nil) == nil
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

      assert %{password: ["should be at least 8 character(s)"]} = errors_on(changeset)
    end
  end

  describe "login_token_changeset/1" do
    test "generates a login token and expiration" do
      operator = Factory.insert_operator_account()

      changeset = OperatorAccount.login_token_changeset(operator)

      assert changeset.changes[:login_token]
      assert changeset.changes[:login_token_expires_at]
      assert String.length(changeset.changes[:login_token]) > 20

      assert DateTime.compare(
               changeset.changes[:login_token_expires_at],
               DateTime.utc_now()
             ) == :gt
    end
  end

  describe "verify_login_token/2" do
    test "returns true for valid unexpired token" do
      operator = Factory.insert_operator_account()

      {:ok, operator} =
        operator
        |> OperatorAccount.login_token_changeset()
        |> Custyard.Repo.update()

      assert OperatorAccount.verify_login_token(operator, operator.login_token)
    end

    test "returns false for wrong token" do
      operator = Factory.insert_operator_account()

      {:ok, operator} =
        operator
        |> OperatorAccount.login_token_changeset()
        |> Custyard.Repo.update()

      refute OperatorAccount.verify_login_token(operator, "wrong-token")
    end

    test "returns false for expired token" do
      operator = Factory.insert_operator_account()

      expired_at = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)

      {:ok, operator} =
        operator
        |> Ecto.Changeset.change(%{
          login_token: "some-token",
          login_token_expires_at: expired_at
        })
        |> Custyard.Repo.update()

      refute OperatorAccount.verify_login_token(operator, "some-token")
    end

    test "returns false for nil token fields" do
      operator = Factory.insert_operator_account()

      refute OperatorAccount.verify_login_token(operator, "any-token")
    end

    test "returns false when token is set but expires_at is nil" do
      operator = Factory.insert_operator_account()

      {:ok, operator} =
        operator
        |> Ecto.Changeset.change(%{login_token: "some-token", login_token_expires_at: nil})
        |> Custyard.Repo.update()

      refute OperatorAccount.verify_login_token(operator, "some-token")
    end
  end

  describe "clear_login_token_changeset/1" do
    test "clears token and expiration" do
      operator = Factory.insert_operator_account()

      {:ok, operator} =
        operator
        |> OperatorAccount.login_token_changeset()
        |> Custyard.Repo.update()

      changeset = OperatorAccount.clear_login_token_changeset(operator)

      assert changeset.changes[:login_token] == nil
      assert changeset.changes[:login_token_expires_at] == nil
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
end
