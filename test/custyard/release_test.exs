defmodule Custyard.ReleaseTest do
  use Custyard.DataCase
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  require Logger

  alias Custyard.Boot.Env
  alias Custyard.{InstanceAdmin, InstanceAdmins, Release}

  defmodule UnavailableRepo do
    def config, do: raise("RELEASE_FAILURE_PRIVATE_CANARY")
  end

  setup do
    previous = System.get_env("INSTANCE_ADMIN_EMAIL")
    on_exit(fn -> restore_env("INSTANCE_ADMIN_EMAIL", previous) end)
    :ok
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  test "release repository entry points preserve privacy before running work" do
    filters = :logger.get_primary_config()[:filters]
    assert List.keymember?(filters, :custyard_log_privacy, 0)

    log =
      capture_log(fn ->
        assert :ok =
                 Release.with_repo(fn ->
                   assert List.keymember?(
                            :logger.get_primary_config()[:filters],
                            :custyard_log_privacy,
                            0
                          )

                   Logger.error("RELEASE_ENTRYPOINT_PRIVATE_CANARY")
                   :ok
                 end)
      end)

    assert log =~ "external_log"
    refute log =~ "RELEASE_ENTRYPOINT_PRIVATE_CANARY"
    assert :logger.get_primary_config()[:filters] == filters
    assert {:ok, %{formatter: {Custyard.Log.Formatter, _}}} = :logger.get_handler_config(:default)
  end

  test "migration and rollback failures cannot escape eval with private exception text" do
    previous_app = System.get_env("FLY_APP_NAME")
    previous_repos = Application.fetch_env!(:custyard, :ecto_repos)
    private = "RELEASE_FAILURE_PRIVATE_CANARY"

    try do
      System.delete_env("FLY_APP_NAME")
      Application.put_env(:custyard, :ecto_repos, [UnavailableRepo])

      tasks = [
        {&Release.migrate/0, "release_migration_failed", "Database migration failed"},
        {fn -> Release.rollback(UnavailableRepo, 1) end, "release_rollback_failed",
         "Database rollback failed"}
      ]

      for {task, event, message} <- tasks do
        log =
          capture_log(fn ->
            try do
              task.()
              flunk("release task should fail before starting the repository")
            rescue
              error in RuntimeError ->
                assert Exception.message(error) == message <> "; see structured diagnostics"
                refute Exception.format(:error, error, __STACKTRACE__) =~ private
            end
          end)

        assert log =~ event
        refute log =~ private
      end
    after
      Application.put_env(:custyard, :ecto_repos, previous_repos)

      if previous_app,
        do: System.put_env("FLY_APP_NAME", previous_app),
        else: System.delete_env("FLY_APP_NAME")
    end
  end

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

  test "help and malformed commands print readable usage before checking database storage" do
    previous = System.get_env("FLY_APP_NAME")
    System.put_env("FLY_APP_NAME", "custyard-cli-usage-test")
    on_exit(fn -> restore_env("FLY_APP_NAME", previous) end)

    # A Repo-backed command would reject the test DB outside /data. Usage
    # must work even when database configuration or storage is unavailable.
    assert capture_io(fn -> assert Release.run_instance_admin_cli(["help"]) == 0 end) =~
             "Usage: bin/instance-admin"

    for argv <- [[], ["bogus"], ["add"], ["remove"], ["list", "extra"]] do
      output = capture_io(:stderr, fn -> assert Release.run_instance_admin_cli(argv) == 1 end)
      assert output =~ "Usage: bin/instance-admin"
      assert output =~ "\nInstance administrators"
      refute output =~ "\\n"
      refute output =~ "Error: \"Usage"
    end

    assert Repo.aggregate(InstanceAdmin, :count) == 0
  end

  test "invalid addresses cannot create installation administrators through the CLI or setup" do
    for email <- ["", "not-an-address", "admin@", "@example.com"] do
      assert capture_io(:stderr, fn ->
               assert Release.run_instance_admin_cli(["add", email]) == 1
             end) =~ "Error:"

      assert {:error, _changeset} = Release.setup_instance_admin(email)
    end

    assert Repo.aggregate(InstanceAdmin, :count) == 0
    assert Repo.aggregate(Custyard.AuditEvent, :count) == 0
  end

  test "setup normalizes an administrator and repeated calls preserve the original identity" do
    assert {:created, admin} = Release.setup_instance_admin(" ADMIN@EXAMPLE.COM ")
    assert admin.email == "admin@example.com"
    assert {:exists, same} = Release.setup_instance_admin("admin@example.com")
    assert same.id == admin.id
    assert Repo.aggregate(InstanceAdmin, :count) == 1
  end

  # Returns {exit_status, stdout, stderr} without halting the VM.
  defp run_cli(argv) do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        stdout =
          capture_io(fn -> send(parent, {:status, Release.run_instance_admin_cli(argv)}) end)

        send(parent, {:stdout, stdout})
      end)

    assert_received {:status, status}
    assert_received {:stdout, stdout}
    {status, stdout, stderr}
  end

  defp run_doctor(argv) do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        stdout = capture_io(fn -> send(parent, {:status, Release.run_doctor_cli(argv)}) end)
        send(parent, {:stdout, stdout})
      end)

    assert_received {:status, status}
    assert_received {:stdout, stdout}
    {status, stdout, stderr}
  end

  defp with_boot_env(env, fun) do
    Application.put_env(:custyard, :boot_env, env)

    try do
      fun.()
    after
      Application.delete_env(:custyard, :boot_env)
    end
  end

  describe "with_repo/1 and the boot verdict" do
    test "an unconfigured verdict prints the report to stderr and refuses" do
      env = Env.read(%{"MAIL_ADAPTOR" => "x"}, config_env: :prod)

      with_boot_env(env, fn ->
        stderr =
          capture_io(:stderr, fn ->
            assert {:error, "configuration is incomplete; see the report above"} =
                     Release.with_repo(fn -> flunk("the repo must not be opened") end)
          end)

        assert stderr =~ "Custyard is not configured yet"
        assert stderr =~ "✗  SECRET_KEY_BASE"
        assert stderr =~ "MAIL_ADAPTOR (did you mean MAIL_ADAPTER)"

        assert {1, "", stderr} = run_cli(["list"])
        assert stderr =~ "Error: configuration is incomplete"
      end)
    end

    test "a configured verdict opens the repo" do
      env =
        Env.read(
          %{
            "SECRET_KEY_BASE" => String.duplicate("s", 64),
            "CREDENTIAL_ENCRYPTION_KEY" => Base.encode64(:crypto.strong_rand_bytes(32)),
            "PHX_HOST" => "custyard.example.com",
            "MAIL_ADAPTER" => "local"
          },
          config_env: :prod
        )

      with_boot_env(env, fn -> assert :ok = Release.with_repo(fn -> :ok end) end)
    end
  end

  describe "run_doctor_cli/1" do
    @describetag :tmp_dir

    test "help prints usage and bad arguments are a usage error" do
      assert {0, stdout, ""} = run_doctor(["help"])
      assert stdout =~ "Usage: bin/doctor"

      for argv <- [
            ["bogus"],
            ["--probe-database", "a", "b"],
            ["--probe-database", ""],
            ["--probe-database", "  ", "--token", "t"],
            ["--probe-database", "--token"],
            ["--probe-database", "x", "--token", "a", "--token", "b"]
          ] do
        assert {1, "", stderr} = run_doctor(argv), "expected a usage error for #{inspect(argv)}"
        assert stderr =~ "Usage: bin/doctor"
      end
    end

    test "prints the boot report and exits by verdict" do
      canary = "CANARY-" <> String.duplicate("z", 60)

      with_boot_env(
        Env.read(%{"SECRET_KEY_BASE" => canary}, config_env: :prod),
        fn ->
          assert {1, stdout, ""} = run_doctor([])
          assert stdout =~ "Custyard is not configured yet"
          assert stdout =~ "✗  PHX_HOST"
          assert stdout =~ "Image"
          assert stdout =~ "Booted"
          refute stdout =~ canary
        end
      )

      configured =
        Env.read(
          %{
            "SECRET_KEY_BASE" => String.duplicate("s", 64),
            "CREDENTIAL_ENCRYPTION_KEY" => Base.encode64(:crypto.strong_rand_bytes(32)),
            "PHX_HOST" => "custyard.example.com",
            "MAIL_ADAPTER" => "local"
          },
          config_env: :prod
        )

      with_boot_env(configured, fn ->
        assert {0, stdout, ""} = run_doctor([])
        assert stdout =~ "Custyard configuration is complete"
      end)
    end

    test "--probe-database without a target exits 1 while the configuration is incomplete",
         %{tmp_dir: dir} do
      env =
        Env.read(
          %{
            "SECRET_KEY_BASE" => String.duplicate("s", 64),
            "DATABASE_PATH" => Path.join(dir, "d.db")
          },
          config_env: :prod
        )

      with_boot_env(env, fn ->
        assert {1, stdout, ""} = run_doctor(["--probe-database"])
        assert stdout =~ "Custyard is not configured yet"
        assert stdout =~ "ok      connected and ran SELECT 1"
      end)
    end

    test "probes a SQLite path and runs the throwaway migration", %{tmp_dir: dir} do
      path = Path.join(dir, "doctor.db")

      assert {0, stdout, ""} = run_doctor(["--probe-database", path])
      assert stdout =~ "kind    sqlite"
      assert stdout =~ "path    #{path}"
      assert stdout =~ "ok      connected and ran SELECT 1"
      assert stdout =~ "ok      create table custyard_doctor_probe"
      assert stdout =~ "ok      insert and read a row"
      assert stdout =~ "ok      drop table custyard_doctor_probe"
      assert stdout =~ "committed; nothing left behind"
      assert File.exists?(path)

      {:ok, db} = Exqlite.Sqlite3.open(path, mode: :readonly)

      {:ok, statement} =
        Exqlite.Sqlite3.prepare(db, "SELECT name FROM sqlite_master WHERE type = 'table'")

      {:ok, rows} = Exqlite.Sqlite3.fetch_all(db, statement)
      Exqlite.Sqlite3.close(db)
      refute ["custyard_doctor_probe"] in rows

      # The running test Repo is untouched by the one-off probe repo.
      assert Repo.aggregate(InstanceAdmin, :count) == 0
    end

    test "reports an unopenable path with the category and the driver error" do
      assert {1, stdout, ""} = run_doctor(["--probe-database", "/dev/null/doctor.db"])
      assert stdout =~ "failed  not_writable: the SQLite file cannot be opened"
      # macOS reports enotdir for a parent that is not a directory, Linux eexist.
      assert stdout =~ ~r/error   e(notdir|exist)/
      refute stdout =~ "custyard_doctor_probe"
    end

    test "reports an unreachable libSQL server and a missing token" do
      assert {1, stdout, ""} = run_doctor(["--probe-database", "libsql://127.0.0.1:1?tls=0"])
      assert stdout =~ "kind    turso"
      assert stdout =~ "failed  unreachable:"
      assert stdout =~ "error   Turso: cannot connect to 127.0.0.1:1"

      assert {1, "", stderr} = run_doctor(["--probe-database", "libsql://db.turso.io"])
      assert stderr =~ "TURSO_AUTH_TOKEN  missing"

      assert {1, "", stderr} = run_doctor(["--probe-database", "relative/path.db"])
      assert stderr =~ "DATABASE_PATH  malformed"
    end

    test "an https:// target is probed as Bunny Database" do
      assert {1, "", stderr} = run_doctor(["--probe-database", "https://127.0.0.1:1"])
      assert stderr =~ "BUNNY_DATABASE_AUTH_TOKEN  missing"

      assert {1, stdout, ""} =
               run_doctor(["--probe-database", "https://127.0.0.1:1", "--token", "t"])

      assert stdout =~ "kind    turso"
      assert stdout =~ "failed  unreachable:"
      refute stdout =~ "custyard_doctor_probe"
    end
  end

  describe "import_legacy_files/0" do
    @describetag :tmp_dir

    # The command takes no options: it reads the configured directories.
    setup %{tmp_dir: dir} do
      keys = [:attachment_dir, :upload_dir]
      previous = Map.new(keys, &{&1, Application.get_env(:custyard, &1)})
      Application.put_env(:custyard, :attachment_dir, Path.join(dir, "attachments"))
      Application.put_env(:custyard, :upload_dir, Path.join(dir, "uploads"))

      on_exit(fn ->
        Enum.each(previous, fn {key, value} -> Application.put_env(:custyard, key, value) end)
      end)
    end

    defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

    defp write!(path, bytes) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
    end

    test "imports what is on disk and prints the counts and what is still pending", %{
      tmp_dir: dir
    } do
      message = Custyard.Factory.insert_message()
      tenant = Integer.to_string(message.tenant_id)
      kept = sha256("%PDF-1.4 kept")
      lost = sha256("%PDF-1.4 lost")

      write!(
        Path.join([dir, "attachments", tenant, binary_part(kept, 0, 2), kept]),
        "%PDF-1.4 kept"
      )

      for {sha, position} <- [{kept, 0}, {lost, 1}] do
        Repo.insert!(%Custyard.MessageAttachment{
          tenant_id: message.tenant_id,
          message_id: message.id,
          position: position,
          state: :fetched,
          sha256: sha,
          size: 13,
          filename: "statement.pdf"
        })
      end

      logo = Ecto.UUID.generate() <> ".png"
      write!(Path.join([dir, "uploads", "logos", logo]), "logo")

      Repo.update_all(from(t in Custyard.Tenant, where: t.id == ^message.tenant_id),
        set: [logo_url: "/uploads/logos/" <> logo]
      )

      {output, log} =
        with_log(fn ->
          capture_io(fn ->
            assert Release.import_legacy_files() ==
                     %{attachments: 1, logos: 1, missing: 1, failed: 0, pending: 1}
          end)
        end)

      assert output =~ """
             Legacy file import
               imported  1 attachment, 1 logo
               missing   1
               failed    0
               pending   1
             Not in the database: 1 referenced file.
             """

      assert output =~ "Removing the volume loses"
      refute output =~ "Every referenced file"

      for private <- [dir, kept, lost, logo, "statement.pdf"] do
        refute output =~ private
        refute log =~ private
      end

      assert log =~ "legacy_file_import_completed"

      assert Custyard.Files.read(Custyard.Files.get(message.tenant_id, :attachment, kept)) ==
               {:ok, "%PDF-1.4 kept"}

      assert Custyard.Files.read(Custyard.Files.get(message.tenant_id, :logo, logo)) ==
               {:ok, "logo"}

      # The lost file's row goes; a rerun then has nothing to do or to report.
      Repo.delete_all(from a in Custyard.MessageAttachment, where: a.sha256 == ^lost)

      assert capture_io(fn ->
               assert Release.import_legacy_files() ==
                        %{attachments: 0, logos: 0, missing: 0, failed: 0, pending: 0}
             end) == """
             Legacy file import
               imported  0 attachments, 0 logos
               missing   0
               failed    0
               pending   0
             Every referenced file is in the database. ATTACHMENT_DIR and UPLOAD_DIR are
             no longer read.
             """
    end

    test "an unconfigured verdict refuses before the database is opened" do
      env = Env.read(%{"MAIL_ADAPTOR" => "x"}, config_env: :prod)

      with_boot_env(env, fn ->
        stderr =
          capture_io(:stderr, fn ->
            assert {:error, "configuration is incomplete; see the report above"} =
                     Release.import_legacy_files()
          end)

        assert stderr =~ "Custyard is not configured yet"
        assert stderr =~ "Error: configuration is incomplete"
      end)
    end
  end

  describe "export_sqlite/1" do
    @describetag :tmp_dir
    @describetag skip: System.get_env("TURSO_TEST_URL") not in [nil, ""]

    test "writes a WAL-mode database with migration history and refuses overwrite", %{
      tmp_dir: dir
    } do
      path = Path.join(dir, "turso-import.db")

      assert capture_io(fn -> assert Release.export_sqlite(path) == path end) =~ "to #{path}"
      assert sqlite_all(path, "PRAGMA journal_mode") == [["wal"]]
      assert [[migrations]] = sqlite_all(path, "SELECT count(*) FROM schema_migrations")
      assert migrations > 0
      assert sqlite_all(path, "PRAGMA integrity_check") == [["ok"]]
      original = File.read!(path)

      assert_raise RuntimeError, ~r/already exists/, fn -> Release.export_sqlite(path) end
      assert File.read!(path) == original
    end
  end

  defp sqlite_all(path, sql) do
    {:ok, db} = Exqlite.Sqlite3.open(path, mode: :readonly)

    try do
      {:ok, statement} = Exqlite.Sqlite3.prepare(db, sql)
      {:ok, rows} = Exqlite.Sqlite3.fetch_all(db, statement)
      rows
    after
      Exqlite.Sqlite3.close(db)
    end
  end
end
