defmodule Custyard.Boot.ProbeTest do
  # Writes Custyard.Boot.State (:persistent_term) and reads the sandboxed
  # Repo for facts: sequential.
  use Custyard.DataCase, async: false

  import Custyard.Factory
  import ExUnit.CaptureLog

  alias Custyard.Boot.{Env, Probe, State}

  @unmounted "35 28 0:28 / / rw,relatime - overlay overlay rw\n"
  @no_fly [storage: [fly_app_name: nil]]

  setup do
    State.reset()
    on_exit(fn -> State.reset() end)
  end

  defp env(vars), do: Env.read(vars, config_env: :prod)

  describe "categorize/1" do
    test "maps SQLite open and lock errors" do
      for message <- [
            "unable to open database file",
            "attempt to write a readonly database",
            "eacces",
            "erofs",
            "enotdir",
            "eexist",
            "enoent",
            "permission denied"
          ] do
        assert Probe.categorize(%Exqlite.Error{message: message}) == :not_writable, message
      end

      for message <- ["database is locked", "SQLITE_BUSY", "database table is locked"] do
        assert Probe.categorize(%Exqlite.Error{message: message}) == :locked, message
      end

      assert Probe.categorize(%Exqlite.Error{message: "no such table: foo"}) == :unknown
    end

    test "maps libSQL transport, TLS and auth errors" do
      refused = "Turso: cannot connect to db.turso.io:443: connection refused"
      nxdomain = "Turso: cannot connect to db.turso.io:443: non-existing domain"
      tls = "Turso: cannot connect to db.turso.io:443: TLS client: In state certify"
      timeout = "Turso: cannot connect to db.turso.io:443: timeout"

      for message <- [refused, nxdomain, tls, timeout] do
        assert Probe.categorize(%DBConnection.ConnectionError{message: message}) ==
                 :unreachable,
               message
      end

      for message <- [
            "Turso: HTTP 401: Unauthorized: `The JWT is invalid`",
            "Turso: HTTP 403: forbidden",
            "Turso: unauthorized"
          ] do
        assert Probe.categorize(%DBConnection.ConnectionError{message: message}) ==
                 :auth_rejected,
               message
      end

      assert Probe.categorize(%DBConnection.ConnectionError{message: "Turso: HTTP 500: boom"}) ==
               :unknown

      assert Probe.categorize(%Mint.TransportError{reason: :nxdomain}) == :unreachable
      assert Probe.categorize(%RuntimeError{message: "something else"}) == :unknown
      assert Probe.categorize(:whatever) == :unknown
    end
  end

  describe "run/2 with a SQLite file" do
    @tag :tmp_dir
    test "connects, records success and facts, and creates the file as the app would",
         %{tmp_dir: dir} do
      path = Path.join(dir, "probe.db")
      env = env(%{"DATABASE_PATH" => path})

      assert :ok = Probe.run(env, @no_fly)
      assert File.exists?(path)

      database = State.get().database
      assert database.status == :ok
      assert database.category == nil
      assert database.attempts == 1
      assert %DateTime{} = database.last_attempt_at
      assert database.facts.kind == :sqlite
      assert database.facts.path == path
      assert database.facts.file_exists? == true
      assert database.facts.mounted? in [true, false, nil]

      assert :ok = Probe.run(env, @no_fly)
      assert State.get().database.attempts == 2
    end

    test "reports a path that cannot be opened without naming it" do
      path = "/dev/null/custyard-canary.db"
      env = env(%{"DATABASE_PATH" => path})

      log =
        capture_log(fn ->
          assert {:error, :not_writable, detail} = Probe.run(env, @no_fly)
          refute detail =~ path
          assert detail =~ "DATABASE_PATH"
        end)

      assert log =~ "boot_database_probe_failed"
      assert log =~ "database_category=not_writable"
      assert log =~ "Exqlite.Error"
      refute log =~ "canary"

      database = State.get().database
      assert database.status == :error
      assert database.category == :not_writable
      assert database.attempts == 1
      assert database.facts.file_exists? == false

      assert {:error, :not_writable, _, %Exqlite.Error{}} = Probe.check(env, @no_fly)
    end

    test "a missing Fly volume is reported before anything is opened" do
      env = env(%{"DATABASE_PATH" => "/data/custyard.db"})

      capture_log(fn ->
        assert {:error, :volume_missing, detail} =
                 Probe.run(env,
                   storage: [
                     fly_app_name: "custyard",
                     upload_dir: "/data/uploads",
                     attachment_dir: "/data/attachments",
                     mountinfo: @unmounted
                   ]
                 )

        assert detail =~ "no mounted volume at /data"
      end)

      assert State.get().database.category == :volume_missing
    end
  end

  describe "run/2 with a remote database" do
    test "an unreachable libSQL server" do
      env = env(%{"DATABASE_URL" => "libsql://127.0.0.1:1?tls=0"})

      capture_log(fn ->
        assert {:error, :unreachable, detail} = Probe.run(env, @no_fly)
        refute detail =~ "127.0.0.1"
      end)

      assert State.get().database.facts.kind == :turso
      refute Map.has_key?(State.get().database.facts, :path)
    end

    test "a postgres:// URL on the SQLite/libSQL build" do
      env = env(%{"DATABASE_URL" => "postgres://user:secret@db.internal/custyard"})

      capture_log(fn ->
        assert {:error, :unknown, detail} = Probe.run(env, @no_fly)
        assert detail =~ "built for SQLite/libSQL"
        refute detail =~ "secret"
      end)
    end

    test "no database at all" do
      env = env(%{"DATABASE_PATH" => "relative/path.db"})
      assert env.settings.database == nil

      capture_log(fn ->
        assert {:error, :unknown, "no database is configured" <> _} = Probe.run(env, @no_fly)
      end)
    end
  end

  describe "facts/1 and repo_config/1" do
    test "adds schema and operator counts while the Repo is running" do
      insert_operator_account(email: "ops@example.com")
      insert_operator_account(email: "admin@custyard.local")

      facts = Probe.facts(env(%{"DATABASE_PATH" => "/data/custyard.db"}))
      assert facts.kind == :sqlite
      assert facts.migrations > 0
      assert facts.operators == 1
    end

    test "builds the Repo configuration runtime.exs writes" do
      assert Probe.repo_config(env(%{"DATABASE_PATH" => "/data/x.db", "POOL_SIZE" => "3"})) ==
               [database: "/data/x.db", journal_mode: :wal, busy_timeout: 5000, pool_size: 3]

      assert Probe.repo_config(
               env(%{"DATABASE_URL" => "libsql://db.turso.io", "TURSO_AUTH_TOKEN" => "t"})
             ) == [turso_url: "libsql://db.turso.io", turso_auth_token: "t", pool_size: 10]

      assert Probe.repo_config(env(%{"DATABASE_URL" => "postgres://db/custyard"})) ==
               [url: "postgres://db/custyard", pool_size: 10]
    end
  end
end
