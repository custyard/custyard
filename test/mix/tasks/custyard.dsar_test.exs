defmodule Mix.Tasks.Custyard.DsarTest do
  # Captures the global stderr device; run alone.
  use Custyard.DataCase, async: false

  import Custyard.Factory
  import ExUnit.CaptureIO

  alias Custyard.{AuditEvent, Message}
  alias Mix.Tasks.Custyard.Dsar

  setup do
    org = insert_organization()
    conv = insert_thread(organization_id: org.id)

    message =
      insert_message(
        thread_id: conv.id,
        sender_email: "alice@customer.example",
        cc_addresses: ["pat@example.com"]
      )

    %{org_id: Integer.to_string(org.id), message: message}
  end

  test "runs the shared command and prints its output", ctx do
    out = capture_io(fn -> Dsar.run(["export", "pat@example.com", "--org", ctx.org_id]) end)

    assert %{"email" => "pat@example.com", "messages" => [%{"roles" => ["cc"]}]} =
             Jason.decode!(out)
  end

  test "erases with --yes", ctx do
    out =
      capture_io(fn -> Dsar.run(["erase", "pat@example.com", "--org", ctx.org_id, "--yes"]) end)

    assert out =~ "Removed the address from 1 message(s) as a recipient."
    assert Repo.get!(Message, ctx.message.id).cc_addresses == []
    assert Repo.aggregate(AuditEvent, :count) == 1
  end

  test "exits with the command's status on a refusal, changing nothing", ctx do
    for argv <- [
          ["erase", "pat@example.com", "--org", ctx.org_id],
          ["erase-contact", "not an address", "--org", ctx.org_id, "--yes"],
          ["export", "pat@example.com"]
        ] do
      {{reason, ""}, err} =
        with_io(:stderr, fn -> with_io(fn -> catch_exit(Dsar.run(argv)) end) end)

      assert reason == {:shutdown, 1}, "#{inspect(argv)} did not exit 1"
      assert err != ""
      refute err =~ "not an address"
    end

    assert Repo.get!(Message, ctx.message.id).cc_addresses == ["pat@example.com"]
    assert Repo.aggregate(AuditEvent, :count) == 0
  end
end
