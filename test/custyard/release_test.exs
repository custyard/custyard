defmodule Custyard.ReleaseTest do
  use Custyard.DataCase
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  require Logger

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

  test "bootstrap ignores absent and blank email configuration" do
    System.delete_env("INSTANCE_ADMIN_EMAIL")
    assert Release.bootstrap_instance_admin() == :ok
    System.put_env("INSTANCE_ADMIN_EMAIL", " \n ")
    assert Release.bootstrap_instance_admin() == :ok
    assert Repo.aggregate(InstanceAdmin, :count) == 0
  end

  test "bootstrap provisions one normalized identity and rejects malformed configuration" do
    System.put_env("INSTANCE_ADMIN_EMAIL", " BOOTSTRAP@EXAMPLE.COM ")

    Logger.put_module_level(InstanceAdmins, :info)
    on_exit(fn -> Logger.delete_module_level(InstanceAdmins) end)

    created_log =
      capture_log([metadata: [:instance_admin_id]], fn ->
        assert Release.bootstrap_instance_admin() == :ok
      end)

    admin = InstanceAdmins.get_by_email("bootstrap@example.com")
    assert admin
    assert created_log =~ "instance_admin_created"
    assert created_log =~ "instance_admin_id=#{admin.id}"
    refute String.downcase(created_log) =~ "bootstrap@example.com"
    assert Release.bootstrap_instance_admin() == :ok
    assert Repo.aggregate(InstanceAdmin, :count) == 1

    System.put_env("INSTANCE_ADMIN_EMAIL", "not-an-address")

    # The eval runner prints an uncaught exception to stderr. The message is
    # fixed and the diagnostic names the rejected field, never its value.
    failed_log =
      capture_log(fn ->
        error =
          assert_raise RuntimeError, ~r/Could not create instance administrator/, fn ->
            Release.bootstrap_instance_admin()
          end

        refute Exception.message(error) =~ "not-an-address"
      end)

    assert failed_log =~ "instance_admin_bootstrap_failed"
    refute failed_log =~ "not-an-address"

    assert Repo.aggregate(InstanceAdmin, :count) == 1
    assert InstanceAdmins.get_by_email("bootstrap@example.com").id == admin.id
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
