defmodule Custyard.Release.AcknowledgmentsTest do
  defp local_authority(tenant_id, channel),
    do: %Custyard.Acknowledgments.LocalAuthority{tenant_id: tenant_id, channel: channel}

  defp ack_scope(tenant_id) do
    key = {__MODULE__, :scope, tenant_id}

    case Process.get(key) do
      nil ->
        scope = Custyard.Factory.staff_scope(tenant_id)
        Process.put(key, scope)
        scope

      scope ->
        scope
    end
  end

  # Reads and replaces the application's acknowledgment configuration.
  use Custyard.DataCase, async: false
  import ExUnit.CaptureIO
  import Custyard.AcknowledgmentsBroker
  alias Custyard.Acknowledgments
  alias Custyard.Acknowledgments.{Integration, Topology}
  alias Custyard.Release.Acknowledgments, as: CLI

  # Runs a command as bin/acknowledgments would in a running VM, capturing both
  # streams and the exit status.
  defp tenant_id do
    case Process.get(:ack_test_tenant_id) || Process.get(:factory_tenant_id) do
      nil ->
        tenant = Custyard.Factory.insert_tenant()
        Process.put(:factory_tenant_id, tenant.id)
        tenant.id

      id ->
        id
    end
  end

  defp cli(argv) do
    argv = argv ++ ["--tenant", Integer.to_string(tenant_id())]
    {{status, out}, err} = with_io(:stderr, fn -> with_io(fn -> CLI.run(argv) end) end)
    %{status: status, out: out, err: err}
  end

  defp put_config(config) do
    previous = Application.get_env(:custyard, :acknowledgments)
    on_exit(fn -> Application.put_env(:custyard, :acknowledgments, previous) end)
    Application.put_env(:custyard, :acknowledgments, config)

    if config[:url] && config[:source] do
      id = tenant_id()
      {:ok, encrypted} = Custyard.Credentials.encrypt(config[:url], "acknowledgments.#{id}.url")

      integration =
        Repo.get_by(Integration, tenant_id: id) ||
          %Integration{}

      integration
      |> Integration.changeset(%{
        tenant_id: id,
        source: config[:source],
        url_ciphertext: encrypted,
        queue: config[:queue],
        enabled: config[:enabled]
      })
      |> Repo.insert_or_update!()
    end
  end

  defp binding_audits,
    do:
      Repo.all(
        from e in Custyard.AuditEvent, where: e.event_type == :acknowledgment_binding_created
      )

  describe "argument handling" do
    test "help prints usage and succeeds" do
      result = cli(["help"])
      assert result.status == 0
      assert result.out =~ "Usage: bin/acknowledgments COMMAND"
      assert result.out =~ "inspect [--evidence]"
      assert result.err == ""
    end

    test "anything unexpected prints usage to stderr, writes nothing and fails" do
      org = Custyard.Factory.insert_organization()

      for argv <- [
            [],
            ["unknown"],
            ["status", "extra"],
            ["status", "--url", "amqp://u:p@h"],
            ["bind", "ots.test", "org-1"],
            ["bind", "ots.test", "org-1", "#{org.id}", "extra"],
            ["bind", "--force", "ots.test", "org-1", "#{org.id}"],
            ["inspect", "--evidence", "now"],
            ["inspect", "--full"],
            ["replay", "one", "two"],
            ["help", "me"]
          ] do
        result = cli(argv)
        assert result.status == 1, "expected #{inspect(argv)} to fail"
        assert result.err =~ "Usage: bin/acknowledgments COMMAND"
        assert result.out == ""
      end

      assert Acknowledgments.list_bindings(ack_scope(tenant_id())) == []
      assert binding_audits() == []
    end
  end

  describe "status without a broker" do
    test "names the secrets to set and never prints values" do
      put_config(
        enabled: true,
        url: nil,
        source: nil,
        queue: "custyard.acknowledgments",
        prefetch: 1
      )

      result = cli(["status"])
      assert result.status == 0
      assert result.out =~ "Consumer: disabled"
      assert result.out =~ "Source: not set"
      assert result.out =~ "Broker URL: not set"
      assert result.out =~ "Configure the tenant acknowledgment integration"
    end

    test "an invalid URL is reported by rule, never by value" do
      put_config(
        enabled: true,
        url: "amqp://custyard:invalid-pw@broker.internal:99999",
        source: "ots.eu.production",
        queue: "custyard.acknowledgments",
        prefetch: 1,
        retry_delays: [10_000],
        confirm_timeout: 5_000,
        reconnect_delay: 5_000
      )

      result = cli(["status"])
      assert result.status == 1
      assert result.err =~ "Invalid configuration: acknowledgments URL is not a valid AMQP URI"
      refute result.out <> result.err =~ "invalid-pw"
      refute result.out <> result.err =~ "broker.internal"
    end

    test "missing tenant selection refuses the command" do
      assert capture_io(:stderr, fn -> assert CLI.run(["status"]) == 1 end) =~ "--tenant"
    end
  end

  describe "bind" do
    test "creates once, reports an existing binding, and audits as cli" do
      org = Custyard.Factory.insert_organization()

      created = cli(["bind", "ots.test", "org-cli", "#{org.id}"])
      assert created.status == 0
      assert created.out =~ "Bound ots.test org-cli to organization #{org.id}"

      again = cli(["bind", "ots.test", "org-cli", "#{org.id}"])
      assert again.status == 0
      assert again.out =~ "already bound to organization #{org.id}; nothing changed"

      assert [
               %{
                 source: "cli",
                 payload: %{"actor" => "cli", "source_organization_id" => "org-cli"}
               }
             ] =
               binding_audits()
    end

    test "reports conflicts, missing organizations and invalid input without writing" do
      org = Custyard.Factory.insert_organization()
      other = Custyard.Factory.insert_organization()

      {:ok, :created, _} =
        Acknowledgments.bind(local_authority(tenant_id(), "cli"), "ots.test", "org-taken", org.id)

      conflict = cli(["bind", "ots.test", "org-taken", "#{other.id}"])
      assert conflict.status == 1
      assert conflict.err =~ "already bound to another organization"

      missing = cli(["bind", "ots.test", "org-new", "999999999"])
      assert missing.status == 1
      assert missing.err =~ "Organization 999999999 does not exist"

      # Beyond signed 64 bits the SQLite driver would raise.
      for id <- ["0", "-4", "12abc", "one", "9223372036854775808", String.duplicate("9", 40)] do
        result = cli(["bind", "ots.test", "org-new", id])
        assert result.status == 1
        assert result.err =~ "CUSTYARD_ORG_ID must be an integer from 1 to 9223372036854775807"
      end

      largest = cli(["bind", "ots.test", "org-new", "9223372036854775807"])
      assert largest.status == 1
      assert largest.err =~ "Organization 9223372036854775807 does not exist"

      invalid = cli(["bind", "ots.test", " padded", "#{org.id}"])
      assert invalid.status == 1
      assert invalid.err =~ "nonblank identities"

      assert Acknowledgments.get_binding(ack_scope(tenant_id()), "ots.test", "org-new") == nil
      assert length(binding_audits()) == 1
    end

    test "prints identities with format and separator characters escaped" do
      org = Custyard.Factory.insert_organization()
      # Valid identities: only C0 controls and DEL are refused there.
      external_id = "org\u202Eevil\u200B\u2028x"

      result = cli(["bind", "ots.test", external_id, "#{org.id}"])
      assert result.status == 0
      assert result.out =~ "Bound ots.test org\\u{202E}evil\\u{200B}\\u{2028}x to organization"
      refute result.out =~ ~r/[\x{202E}\x{200B}\x{2028}]/u
    end
  end

  # Release.migrate's order: opening SQLite before the check would create an
  # empty database on the root filesystem when the Fly volume is missing.
  describe "storage check" do
    setup do
      previous = System.get_env("FLY_APP_NAME")
      System.put_env("FLY_APP_NAME", "custyard-test")

      on_exit(fn ->
        if previous,
          do: System.put_env("FLY_APP_NAME", previous),
          else: System.delete_env("FLY_APP_NAME")
      end)
    end

    test "runs before the Repo starts and before anything is written" do
      org = Custyard.Factory.insert_organization()

      # DATABASE_PATH on a local database; over Turso (TURSO_TEST_URL) there
      # is none, and the uploads directory is the first path refused.
      for argv <- [["bind", "ots.test", "org-fly", "#{org.id}"], ["replay"]] do
        assert_raise RuntimeError,
                     ~r/(DATABASE_PATH|UPLOAD_DIR) must point inside the mounted \/data/,
                     fn ->
                       with_io(:stderr, fn ->
                         with_io(fn ->
                           CLI.run(argv ++ ["--tenant", Integer.to_string(tenant_id())],
                             mode: :release
                           )
                         end)
                       end)
                     end
      end

      assert Acknowledgments.list_bindings(ack_scope(tenant_id())) == []
      assert binding_audits() == []
    end
  end

  describe "broker commands" do
    @describetag :rabbitmq
    @describetag skip: is_nil(System.get_env("ACKNOWLEDGMENTS_TEST_AMQP_URL"))

    setup do
      setup_topology(source: "ots.integration")
    end

    test "status lists counts per queue and never the URL", ctx do
      put_failure(ctx, Jason.encode!(evidence()))
      await_failures(ctx, 1)

      result = cli(["status"])
      assert result.status == 0
      assert result.out =~ "Source: ots.integration"
      assert result.out =~ "Broker URL: set"
      assert result.out =~ "#{ctx.config[:queue]}: 0 ready, 0 consumers"
      assert result.out =~ "#{Topology.failure(ctx.config)}: 1 ready, 0 consumers"
      refute result.out =~ ctx.config[:url]
      refute result.out =~ URI.parse(ctx.config[:url]).userinfo
    end

    test "provision is idempotent and lists the queues", ctx do
      result = cli(["provision"])
      assert result.status == 0
      assert result.out =~ "Provisioned #{ctx.config[:queue]}\n"
      assert result.out =~ "Provisioned #{Topology.retry(ctx.config, 1)}\n"
      assert result.out =~ "Provisioned #{Topology.failure(ctx.config)}\n"
    end

    test "an unreachable broker is a short message on stderr", ctx do
      unreachable = %{URI.parse(ctx.config[:url]) | host: "127.0.0.1", port: 1}
      put_config(Keyword.put(ctx.config, :url, URI.to_string(unreachable)))

      result = cli(["status"])
      assert result.status == 1
      assert result.err == "The broker is unreachable\n"
    end

    test "inspect prints sanitized fields; --evidence adds a warning and the body", ctx do
      body = Jason.encode!(evidence())
      put_failure(ctx, body)
      await_failures(ctx, 1)

      summary = cli(["inspect"])
      assert summary.status == 0
      assert summary.out =~ "Submission ID: stable"
      assert summary.out =~ "Failure category: unmapped_organization"
      assert summary.out =~ "Attempt: 4"
      refute summary.out =~ "Versioned Colonel statement"

      await_failures(ctx, 1)
      full = cli(["inspect", "--evidence"])
      assert full.status == 0
      assert full.err =~ "WARNING: the full original evidence follows"
      assert full.out =~ "\n  | " <> body <> "\n"
      await_failures(ctx, 1)
    end

    test "inspect --evidence escapes a body with terminal control bytes", ctx do
      put_failure(ctx, "\e]0;owned\a{bad\r\xFF")
      await_failures(ctx, 1)

      full = cli(["inspect", "--evidence"])
      assert full.out =~ "unreadable"
      refute full.out =~ ~r/[\e\a\r]/
      assert full.out =~ "  | \\u{1B}]0;owned\\u{7}{bad\\u{D}\\xFF\n"
    end

    # Every body line is prefixed, so a newline in the evidence cannot start a
    # line that reads like part of the summary.
    test "inspect --evidence cannot forge summary lines", ctx do
      put_failure(ctx, "{bad\n  Submission ID: forged\n\u2028Attempt: 1")
      await_failures(ctx, 1)

      full = cli(["inspect", "--evidence"])
      [_summary, evidence] = String.split(full.out, ~r/^Evidence.*\n/m, parts: 2)

      assert String.split(evidence, "\n", trim: true) == [
               "  | {bad",
               "  |   Submission ID: forged",
               "  | \\u{2028}Attempt: 1"
             ]

      refute full.out =~ ~r/^  Submission ID: forged/m
    end

    test "inspect escapes bidi, zero-width and separator characters in identities", ctx do
      put_failure(ctx, Jason.encode!(evidence(%{"submission_id" => "ok\u202Edi\u200Bx\u2029y"})))
      await_failures(ctx, 1)

      summary = cli(["inspect"])
      assert summary.out =~ "  Submission ID: ok\\u{202E}di\\u{200B}x\\u{2029}y\n"
      refute summary.out =~ ~r/[\x{202E}\x{200B}\x{2029}]/u
    end

    test "replay with a submission ID is guarded, and audited as cli", ctx do
      put_failure(ctx, Jason.encode!(evidence(%{"submission_id" => "first"})))
      put_failure(ctx, Jason.encode!(evidence(%{"submission_id" => "second"})))
      await_failures(ctx, 2)

      changed = cli(["replay", "second"])
      assert changed.status == 1
      assert changed.err =~ "changed; inspect again"
      await_failures(ctx, 2)

      assert cli(["replay", "first"]).status == 0
      await_failures(ctx, 1)

      unguarded = cli(["replay"])
      assert unguarded.status == 0
      assert unguarded.out =~ "Replayed the oldest failed message"

      assert cli(["replay"]).out =~ "No failed messages"

      outcomes =
        Repo.all(
          from e in Custyard.AuditEvent,
            where: e.event_type == :acknowledgment_replayed,
            order_by: e.id
        )
        |> Enum.map(&{&1.source, &1.payload["outcome"], &1.payload["submission_id"]})

      assert outcomes == [
               {"cli", "changed", "first"},
               {"cli", "started", "first"},
               {"cli", "replayed", "first"},
               {"cli", "started", "second"},
               {"cli", "replayed", "second"},
               {"cli", "empty", nil}
             ]
    end
  end
end
