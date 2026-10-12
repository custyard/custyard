defmodule Mix.Tasks.Dev.CreateOperatorTest do
  use Custyard.DataCase, async: false

  import ExUnit.CaptureIO

  alias Custyard.{AuditEvent, OperatorAccount}
  alias Mix.Tasks.Dev.CreateOperator

  setup do
    Mix.Task.reenable("dev.create_operator")
    :ok
  end

  test "creates the dev default admin@custyard.local through the shared path" do
    output = capture_io(fn -> CreateOperator.run([]) end)

    assert output =~ "OPERATOR ACCOUNT CREATED"

    assert %{role: "super_admin", id: id} =
             Repo.get_by!(OperatorAccount, email: "admin@custyard.local")

    assert [%{source: "mix", payload: %{"via" => "mix", "operator_id" => ^id}}] =
             Repo.all(from(a in AuditEvent, where: a.event_type == :operator_created))
  end

  test "stores --email normalized and reports an existing account unmodified" do
    capture_io(fn -> CreateOperator.run(["--email", "Dev.Ops@Example.com"]) end)
    assert Repo.get_by!(OperatorAccount, email: "dev.ops@example.com")

    output = capture_io(fn -> CreateOperator.run(["--email", "DEV.OPS@example.com"]) end)
    assert output =~ "already exists for: dev.ops@example.com (role super_admin), not modified"
    assert Repo.aggregate(OperatorAccount, :count) == 1
  end

  test "raises on an invalid email" do
    assert_raise Mix.Error, ~r/must be a valid email address/, fn ->
      capture_io(fn -> CreateOperator.run(["--email", "nope"]) end)
    end
  end
end
