defmodule Custyard.ReleaseTest do
  use Custyard.DataCase
  import ExUnit.CaptureIO
  alias Custyard.{InstanceAdmins, Release}

  test "instance admin CLI manages installation identities without tenant privileges" do
    assert capture_io(fn ->
             assert Release.run_instance_admin_cli(["add", "ADMIN@EXAMPLE.COM"]) == 0
           end) =~ "created instance admin"

    assert InstanceAdmins.get_by_email("admin@example.com")

    assert capture_io(fn -> assert Release.run_instance_admin_cli(["list"]) == 0 end) =~
             "admin@example.com"

    assert capture_io(:stderr, fn ->
             assert Release.run_instance_admin_cli(["remove", "admin@example.com"]) == 1
           end) =~ "last_admin"

    assert capture_io(fn ->
             assert Release.run_instance_admin_cli(["add", "second@example.com"]) == 0
           end) =~ "created instance admin"

    assert capture_io(fn ->
             assert Release.run_instance_admin_cli(["remove", "admin@example.com"]) == 0
           end) =~ "Removed instance admin"

    refute InstanceAdmins.get_by_email("admin@example.com")
  end

  test "obsolete customer organization and staff switches are rejected" do
    assert capture_io(:stderr, fn ->
             assert Release.run_instance_admin_cli([
                      "add",
                      "bad@example.com",
                      "--organization",
                      "1"
                    ]) == 1
           end) =~ "Usage"

    refute InstanceAdmins.get_by_email("bad@example.com")
  end
end
