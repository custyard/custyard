defmodule Mix.Tasks.Dev.ResetOperatorPasswordTest do
  @moduledoc """
  Tests for the Dev.ResetOperatorPassword mix task.

  This task resets passwords for operator accounts in development.
  Tests cover: generating random passwords, using provided passwords,
  --email flag, and error handling when operator not found.
  """
  use Custyard.DataCase, async: false

  alias Mix.Tasks.Dev.ResetOperatorPassword
  alias Custyard.{Factory, OperatorAccount, Repo}

  describe "run/1 with default email" do
    test "generates random password when none provided" do
      Factory.insert_operator_account(email: "admin@custyard.local")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          ResetOperatorPassword.run([])
        end)

      assert output =~ "OPERATOR PASSWORD RESET"
      assert output =~ "Email:    admin@custyard.local"
      assert output =~ "Password:"
      assert output =~ "/operator/login"

      # Extract password from output and verify it was set
      [_, password] = Regex.run(~r/Password:\s+(\S+)/, output)
      assert String.length(password) == 16

      # Verify password actually works
      operator = Repo.get_by!(OperatorAccount, email: "admin@custyard.local")
      assert OperatorAccount.verify_password(operator, password)
    end

    test "uses provided password when given" do
      Factory.insert_operator_account(email: "admin@custyard.local")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          ResetOperatorPassword.run(["mynewpassword123"])
        end)

      assert output =~ "OPERATOR PASSWORD RESET"
      assert output =~ "Password: mynewpassword123"

      # Verify password was set correctly
      operator = Repo.get_by!(OperatorAccount, email: "admin@custyard.local")
      assert OperatorAccount.verify_password(operator, "mynewpassword123")
    end
  end

  describe "run/1 with --email flag" do
    test "resets password for specified email" do
      Factory.insert_operator_account(email: "other@example.com")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          ResetOperatorPassword.run(["--email", "other@example.com", "custompass123"])
        end)

      assert output =~ "Email:    other@example.com"
      assert output =~ "Password: custompass123"

      operator = Repo.get_by!(OperatorAccount, email: "other@example.com")
      assert OperatorAccount.verify_password(operator, "custompass123")
    end

    test "generates random password for specified email when no password provided" do
      Factory.insert_operator_account(email: "agent@company.com")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          ResetOperatorPassword.run(["--email", "agent@company.com"])
        end)

      assert output =~ "Email:    agent@company.com"
      assert output =~ "Password:"

      # Extract and verify random password
      [_, password] = Regex.run(~r/Password:\s+(\S+)/, output)
      operator = Repo.get_by!(OperatorAccount, email: "agent@company.com")
      assert OperatorAccount.verify_password(operator, password)
    end
  end

  describe "run/1 error handling" do
    test "shows error when operator not found with default email" do
      # No operator created

      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          ResetOperatorPassword.run([])
        end)

      assert output =~ "No operator account found with email: admin@custyard.local"
    end

    test "shows error when operator not found with custom email" do
      # No operator created

      output =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          ResetOperatorPassword.run(["--email", "nonexistent@example.com"])
        end)

      assert output =~ "No operator account found with email: nonexistent@example.com"
    end
  end

  describe "run/1 password validation" do
    test "accepts minimum length password" do
      Factory.insert_operator_account(email: "admin@custyard.local")

      output =
        ExUnit.CaptureIO.capture_io(fn ->
          ResetOperatorPassword.run(["12345678"])
        end)

      assert output =~ "Password: 12345678"

      operator = Repo.get_by!(OperatorAccount, email: "admin@custyard.local")
      assert OperatorAccount.verify_password(operator, "12345678")
    end
  end
end
