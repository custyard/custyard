defmodule Custyard.ReleaseTest do
  # The CLI captures the global stderr device; run alone.
  use Custyard.DataCase, async: false

  import Custyard.Factory
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Custyard.{AuditEvent, Message, OperatorAccount, OperatorAccounts, Organization, Release}

  # Returns {exit_status, stdout, stderr} without halting the VM.
  defp run_cli(argv) do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        stdout = capture_io(fn -> send(parent, {:status, Release.run_operator_cli(argv)}) end)
        send(parent, {:stdout, stdout})
      end)

    assert_received {:status, status}
    assert_received {:stdout, stdout}
    {status, stdout, stderr}
  end

  # The bootstrap logs at info; the test config caps Logger at warning.
  defp capture_info_log(fun) do
    modules = [Release, OperatorAccounts]
    Enum.each(modules, &Logger.put_module_level(&1, :info))

    try do
      capture_log(fun)
    after
      Enum.each(modules, &Logger.delete_module_level/1)
    end
  end

  defp operator_count, do: Repo.aggregate(OperatorAccount, :count)

  defp audit_events(type) do
    Repo.all(from(a in AuditEvent, where: a.event_type == ^type, order_by: a.id))
  end

  describe "run_operator_cli/1 usage" do
    test "help prints usage to stdout and succeeds" do
      assert {0, stdout, ""} = run_cli(["help"])
      assert stdout =~ "Usage: bin/operator COMMAND"
      assert stdout =~ "add EMAIL [--role super_admin|admin|agent] [--organization ID]"
      assert stdout =~ "remove EMAIL"
    end

    test "bad arguments print usage to stderr, write nothing, and exit 1" do
      org = insert_organization()

      for argv <- [
            [],
            ["bogus"],
            ["help", "extra"],
            ["add"],
            ["add", "a@example.com", "b@example.com"],
            ["add", "a@example.com", "--bogus"],
            ["add", "a@example.com", "--role"],
            ["add", "a@example.com", "--organization", "abc"],
            [
              "add",
              "a@example.com",
              "--role",
              "agent",
              "--organization",
              "#{org.id}",
              "--role",
              "super_admin"
            ],
            ["list", "extra"],
            ["list", "--all"],
            ["remove"],
            ["remove", "a@example.com", "b@example.com"],
            ["remove", "a@example.com", "--force"],
            # cast/4 would turn an empty role into the super_admin default
            ["add", "a@example.com", "--role", ""],
            ["add", "a@example.com", "--role", "  "],
            ["add", "a@example.com", "--role", "owner"],
            ["add", "a@example.com", "--role", "Super_Admin"],
            # ids are signed 64-bit; anything else made the driver raise
            ["add", "a@example.com", "--role", "agent", "--organization", "0"],
            ["add", "a@example.com", "--role", "agent", "--organization", "-1"],
            [
              "add",
              "a@example.com",
              "--role",
              "agent",
              "--organization",
              "99999999999999999999999"
            ],
            ["add", "a@example.com", "--role", "agent", "--organization", "9223372036854775808"]
          ] do
        assert {1, "", stderr} = run_cli(argv), "expected a usage error for #{inspect(argv)}"
        assert stderr =~ "Usage: bin/operator COMMAND"
      end

      assert operator_count() == 0
      assert Repo.aggregate(AuditEvent, :count) == 0
    end
  end

  describe "run_operator_cli/1 add" do
    test "creates a super_admin by default and audits it as cli" do
      assert {0, stdout, ""} = run_cli(["add", "First.Admin@Example.com"])

      operator = Repo.get_by!(OperatorAccount, email: "first.admin@example.com")
      assert operator.role == "super_admin"
      assert stdout =~ "Created operator #{operator.id}: first.admin@example.com (super_admin)"

      assert [%{source: "cli", payload: %{"via" => "cli", "operator_id" => id}}] =
               audit_events(:operator_created)

      assert id == operator.id
    end

    test "creates an admin or agent for an organization" do
      org = insert_organization()

      assert {0, stdout, ""} =
               run_cli([
                 "add",
                 "agent@example.com",
                 "--role",
                 "agent",
                 "--organization",
                 "#{org.id}"
               ])

      assert stdout =~ "(agent, organization #{org.id})"

      assert %{role: "agent", organization_id: org_id} =
               Repo.get_by!(OperatorAccount, email: "agent@example.com")

      assert org_id == org.id
    end

    test "takes switches before the email and an email that looks like a switch after --" do
      assert {0, _, ""} = run_cli(["add", "--role", "super_admin", "lead@example.com"])
      assert {0, _, ""} = run_cli(["add", "--", "-dash@example.com"])
      assert Repo.get_by(OperatorAccount, email: "-dash@example.com")
    end

    test "reports an existing account without modifying it" do
      org = insert_organization()

      existing =
        insert_operator_account(email: "ops@example.com", role: "admin", organization_id: org.id)

      before = Repo.get!(OperatorAccount, existing.id)

      assert {0, stdout, ""} = run_cli(["add", "OPS@example.com", "--role", "super_admin"])
      assert stdout =~ "ops@example.com exists (role admin), not modified"
      assert Repo.get!(OperatorAccount, existing.id) == before
      assert audit_events(:operator_created) == []
    end

    test "reports invalid input on stderr and exits 1" do
      assert {1, "", stderr} = run_cli(["add", "not-an-email"])
      assert stderr =~ "Error: email: must be a valid email address"

      assert {1, "", stderr} = run_cli(["add", "admin@example.com", "--role", "admin"])
      assert stderr =~ "admin operators must be assigned to an organization"

      assert {1, "", stderr} =
               run_cli([
                 "add",
                 "agent@example.com",
                 "--role",
                 "agent",
                 "--organization",
                 "999999"
               ])

      assert stderr =~ "organization 999999 does not exist"

      assert {1, "", stderr} = run_cli(["add", "admin@custyard.local"])
      assert stderr =~ "non-routable placeholder"

      # The largest valid id parses, and is reported missing rather than raising.
      assert {1, "", stderr} =
               run_cli([
                 "add",
                 "big@example.com",
                 "--role",
                 "agent",
                 "--organization",
                 "9223372036854775807"
               ])

      assert stderr =~ "organization 9223372036854775807 does not exist"

      assert operator_count() == 0
    end
  end

  describe "run_operator_cli/1 list" do
    test "says how to create the first operator when there are none" do
      assert {0, stdout, ""} = run_cli(["list"])
      assert stdout =~ "No operator accounts. Create one with: bin/operator add EMAIL"
    end

    test "prints every operator and flags accounts that cannot log in" do
      org = insert_organization()
      doomed_org = insert_organization()
      fine = insert_operator_account(email: "fine@example.com")

      agent =
        insert_operator_account(
          email: "agent@example.com",
          role: "agent",
          organization_id: org.id
        )

      placeholder = insert_operator_account(email: "admin@custyard.local")

      orphan =
        insert_operator_account(
          email: "orphan@example.com",
          role: "admin",
          organization_id: doomed_org.id
        )

      Repo.delete!(doomed_org)

      Repo.query!(
        "INSERT INTO operator_accounts (email, role, inserted_at, updated_at) " <>
          "VALUES ('Mixed@Example.com', 'super_admin', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')"
      )

      assert {0, stdout, ""} = run_cli(["list"])
      [header | rows] = String.split(stdout, "\n", trim: true)
      assert header =~ ~r/^ID\s+EMAIL\s+ROLE\s+ORGANIZATION\s+CREATED\s+NOTES$/
      assert length(rows) == 5

      row = fn email -> Enum.find(rows, &(&1 =~ email)) end

      assert row.("fine@example.com") =~
               ~r/^#{fine.id}\s+fine@example.com\s+super_admin\s+-\s+\d{4}-/

      refute row.("fine@example.com") =~ "cannot log in"

      assert row.("agent@example.com") =~
               ~r/^#{agent.id}\s+agent@example.com\s+agent\s+#{org.id}\s/

      assert row.("admin@custyard.local") =~ ~r/^#{placeholder.id}\s/
      assert row.("admin@custyard.local") =~ "non-routable address"
      assert row.("Mixed@Example.com") =~ "email not normalized"
      assert row.("orphan@example.com") =~ ~r/^#{orphan.id}\s+orphan@example.com\s+admin\s+-\s/
      assert row.("orphan@example.com") =~ "no organization"
    end

    test "never prints control or format characters from a stored email" do
      for email <- ["evil\e[2J@example.com", "rtl\u202Emoc.elpmaxe@x.com"] do
        Repo.query!(
          "INSERT INTO operator_accounts (email, role, inserted_at, updated_at) " <>
            "VALUES (?, 'super_admin', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z')",
          [email]
        )
      end

      assert {0, stdout, ""} = run_cli(["list"])
      refute stdout =~ "\e"
      refute stdout =~ "\u202E"
      assert stdout =~ ~S(evil\u{1B}[2J@example.com)
      assert stdout =~ ~S(rtl\u{202E}moc.elpmaxe@x.com)
    end
  end

  describe "run_operator_cli/1 remove" do
    test "removes an operator and audits it as cli" do
      insert_operator_account(email: "keeper@example.com")
      leaver = insert_operator_account(email: "leaver@example.com")

      assert {0, stdout, ""} = run_cli(["remove", "Leaver@Example.com"])
      assert stdout =~ "Removed operator #{leaver.id}: leaver@example.com (super_admin)"
      refute Repo.get(OperatorAccount, leaver.id)
      assert [%{source: "cli", payload: %{"via" => "cli"}}] = audit_events(:operator_removed)
    end

    test "mentions cleared message attribution" do
      insert_operator_account(email: "keeper@example.com")
      org = insert_organization()

      mod =
        insert_operator_account(email: "mod@example.com", role: "admin", organization_id: org.id)

      message = insert_message(conversation_id: insert_conversation(organization_id: org.id).id)

      Repo.update_all(from(m in Message, where: m.id == ^message.id),
        set: [deleted_by_operator_id: mod.id, deleted_at: DateTime.utc_now(:second)]
      )

      assert {0, stdout, ""} = run_cli(["remove", "mod@example.com"])
      assert stdout =~ "Cleared the deleted-by operator on 1 soft-deleted message(s)"
    end

    test "refuses to remove the last super_admin" do
      only = insert_operator_account(email: "only@example.com")

      assert {1, "", stderr} = run_cli(["remove", "only@example.com"])
      assert stderr =~ "Error: refusing to remove the last super_admin"
      assert Repo.get(OperatorAccount, only.id)
    end

    test "reports an unknown email" do
      assert {1, "", stderr} = run_cli(["remove", "ghost@example.com"])
      assert stderr =~ "Error: no operator with email ghost@example.com"
    end
  end

  describe "bootstrap_operator/1" do
    test "unset with no operators logs how to create the first one" do
      for value <- [nil, "", "   "] do
        log = capture_info_log(fn -> assert :ok = Release.bootstrap_operator(value) end)
        assert log =~ "No operator accounts exist"
        assert log =~ "OPERATOR_EMAIL"
        assert log =~ "bin/operator add"
      end

      assert operator_count() == 0
    end

    test "unset with operators logs one line on adding more" do
      insert_operator_account(email: "ops@example.com")

      log = capture_info_log(fn -> assert :ok = Release.bootstrap_operator(nil) end)
      assert log =~ "OPERATOR_EMAIL is not set; add operators with `bin/operator add EMAIL`"
      refute log =~ "No operator accounts exist"
    end

    test "set creates a super_admin via boot and recommends unsetting it" do
      log =
        capture_info_log(fn -> assert :ok = Release.bootstrap_operator(" First@Example.com ") end)

      operator = Repo.get_by!(OperatorAccount, email: "first@example.com")
      assert operator.role == "super_admin"
      assert log =~ "Created operator #{operator.id} first@example.com"
      assert log =~ "via boot"
      assert log =~ "Unset it after the first login"

      assert [%{source: "boot", payload: %{"via" => "boot", "email" => "first@example.com"}}] =
               audit_events(:operator_created)
    end

    test "set to an existing account reports it unmodified" do
      org = insert_organization()

      existing =
        insert_operator_account(email: "ops@example.com", role: "admin", organization_id: org.id)

      before = Repo.get!(OperatorAccount, existing.id)

      log = capture_info_log(fn -> assert :ok = Release.bootstrap_operator("OPS@example.com") end)

      assert log =~ "OPERATOR_EMAIL=ops@example.com exists (role admin), not modified"
      assert log =~ "Unset it after the first login"
      assert Repo.get!(OperatorAccount, existing.id) == before
      assert audit_events(:operator_created) == []
    end

    test "an invalid value is an error and writes nothing" do
      capture_info_log(fn ->
        assert {:error, "email: must be a valid email address"} =
                 Release.bootstrap_operator("not-an-email")

        assert {:error, message} = Release.bootstrap_operator("admin@custyard.local")
        assert message =~ "non-routable placeholder"
      end)

      assert operator_count() == 0
    end

    test "warns while a super_admin admin@custyard.local exists, and leaves it alone" do
      placeholder = insert_operator_account(email: "admin@custyard.local")
      before = Repo.get!(OperatorAccount, placeholder.id)

      for value <- [nil, "admin@custyard.local", "ops@example.com"] do
        log = capture_info_log(fn -> assert :ok = Release.bootstrap_operator(value) end)
        assert log =~ "admin@custyard.local (super_admin, id #{placeholder.id})"
        assert log =~ "bin/operator remove admin@custyard.local"
      end

      assert Repo.get!(OperatorAccount, placeholder.id) == before
    end

    test "never creates admin@custyard.local" do
      capture_info_log(fn -> Release.bootstrap_operator(nil) end)
      refute Repo.get_by(OperatorAccount, email: "admin@custyard.local")
    end
  end

  describe "setup_operator/1,2" do
    test "creates through the shared path and reports an existing account" do
      output =
        capture_io(fn ->
          assert {:created, %OperatorAccount{email: "ops@example.com"}} =
                   Release.setup_operator("Ops@Example.com")
        end)

      assert output =~ "Created operator"
      assert [%{source: "cli"}] = audit_events(:operator_created)

      output =
        capture_io(fn ->
          assert {:exists, _} = Release.setup_operator("ops@example.com", role: "agent")
        end)

      assert output =~ "ops@example.com exists (role super_admin), not modified"
    end

    test "accepts a role and organization" do
      %Organization{id: org_id} = insert_organization()

      capture_io(fn ->
        assert {:created, %{role: "agent", organization_id: ^org_id}} =
                 Release.setup_operator("agent@example.com",
                   role: "agent",
                   organization_id: org_id
                 )
      end)
    end

    test "raises on invalid input" do
      assert_raise ArgumentError, ~r/must be a valid email address/, fn ->
        Release.setup_operator("nope")
      end
    end

    test "raises on an empty or unknown role instead of creating a super_admin" do
      for role <- ["", "   ", nil, "owner"] do
        assert_raise ArgumentError, ~r/role: must be one of: super_admin, admin, agent/, fn ->
          Release.setup_operator("empty-role@example.com", role: role)
        end
      end

      assert operator_count() == 0
    end
  end
end
