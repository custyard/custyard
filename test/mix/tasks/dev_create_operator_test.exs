defmodule Mix.Tasks.Dev.CreateOperatorTest do
  use Custyard.DataCase
  import ExUnit.CaptureIO
  alias Custyard.{AuditEvent, InstanceAdmin}
  alias Mix.Tasks.Dev.CreateOperator

  setup do
    Mix.Task.reenable("dev.create_operator")
    original = System.get_env("INSTANCE_ADMIN_EMAIL")
    System.delete_env("INSTANCE_ADMIN_EMAIL")

    on_exit(fn ->
      if original,
        do: System.put_env("INSTANCE_ADMIN_EMAIL", original),
        else: System.delete_env("INSTANCE_ADMIN_EMAIL")
    end)

    :ok
  end

  test "requires explicit bootstrap identity" do
    assert_raise Mix.Error, ~r/INSTANCE_ADMIN_EMAIL/, fn -> CreateOperator.run([]) end
    assert Repo.aggregate(InstanceAdmin, :count) == 0
  end

  test "operator bootstrap uses configured email without domain-derived privileges" do
    System.put_env("INSTANCE_ADMIN_EMAIL", "Ops@Custyard.com")
    output = capture_io(fn -> CreateOperator.run([]) end)
    assert output =~ "INSTANCE ADMIN ACCOUNT CREATED"
    assert Repo.get_by!(InstanceAdmin, email: "ops@custyard.com")
    assert Repo.get_by!(AuditEvent, event_type: :instance_admin_created).tenant_id == nil
  end

  test "stores explicit email normalized and reports existing account without changes" do
    capture_io(fn -> CreateOperator.run(["--email", "Dev.Ops@Example.com"]) end)
    assert Repo.get_by!(InstanceAdmin, email: "dev.ops@example.com")
    output = capture_io(fn -> CreateOperator.run(["--email", "DEV.OPS@example.com"]) end)
    assert output =~ "already exists for: dev.ops@example.com"
    assert Repo.aggregate(InstanceAdmin, :count) == 1
  end

  test "raises on invalid email" do
    assert_raise Mix.Error, ~r/must be a valid email address/, fn ->
      capture_io(fn -> CreateOperator.run(["--email", "nope"]) end)
    end
  end
end
