defmodule Custyard.StorageTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Custyard.Storage

  @mounted "36 28 0:29 / /data rw,relatime - ext4 /dev/vdb rw\n"
  @unmounted "35 28 0:28 / / rw,relatime - overlay overlay rw\n"
  @one_machine {:ok, ["080e94edf34038"]}
  @two_machines {:ok, ["080e94edf34038", "d8d0066f561338"]}
  @canary "private-person@example.test-credential\r\nFORGED EVENT"

  @fly [
    fly_app_name: "custyard",
    repo_config: [database: "/data/custyard.db"],
    mountinfo: @mounted,
    machine_ids: @one_machine
  ]

  @remote_databases [
    postgres: [url: "postgres://localhost/custyard"],
    turso: [turso_url: "libsql://custyard-acme.turso.io"],
    bunny: [turso_url: "https://database.example", turso_provider: :bunny]
  ]

  @bunny [provider: :bunny, repo_config: @remote_databases[:bunny]]

  defp check(overrides), do: Storage.check(Keyword.merge(@fly, overrides))

  test "allows a SQLite database on a mounted Fly volume" do
    assert :ok == check([])
    assert :ok == Storage.validate_fly_storage!(@fly)
  end

  test "the upload and attachment directories are not checked" do
    # Both are configured outside /data in the test environment.
    for key <- [:upload_dir, :attachment_dir] do
      refute String.starts_with?(Application.fetch_env!(:custyard, key), "/data/")
    end

    assert :ok == check([])
    assert :ok == check(repo_config: @remote_databases[:turso], sqlite_path: "/nonexistent")
  end

  test "reports a missing volume even when /data exists in the image" do
    assert {:error, :volume_missing, detail} = check(mountinfo: @unmounted)
    assert detail =~ "no mounted volume at /data"
    assert detail =~ "SQLite"
    refute detail =~ "uploads"

    assert_raise RuntimeError, ~r/no mounted volume at \/data/, fn ->
      Storage.validate_fly_storage!(Keyword.put(@fly, :mountinfo, @unmounted))
    end
  end

  test "reports a SQLite database outside the Fly volume" do
    assert {:error, :volume_missing, "DATABASE_PATH must point inside" <> _} =
             check(repo_config: [database: "/tmp/custyard.db"])

    assert_raise RuntimeError, ~r/DATABASE_PATH must point inside/, fn ->
      Storage.validate_fly_storage!(Keyword.put(@fly, :repo_config, database: "/tmp/custyard.db"))
    end
  end

  test "path validation never echoes a configured path" do
    path = "/tmp/" <> @canary

    assert {:error, :volume_missing, detail} = check(repo_config: [database: path])
    assert detail == "DATABASE_PATH must point inside the mounted /data volume on Fly.io"
    refute detail =~ @canary
  end

  test "mount read failures retain safe classification without raw details" do
    for {reason, expected} <- [
          {:eacces, "eacces"},
          {:enoent, "enoent"},
          {%File.Error{reason: :eacces, path: @canary, action: "read"}, "exception"},
          {{:private_failure, @canary}, "unclassified_error"}
        ] do
      log =
        capture_log(fn ->
          assert {:error, :volume_missing, detail} = check(mountinfo: {:error, reason})

          assert detail ==
                   "Cannot verify Fly volume mount at /data; check the filesystem error event"

          refute detail =~ @canary
        end)

      assert log =~ "fly_mount_verification_failed"
      assert log =~ expected
      refute log =~ @canary
    end
  end

  test "does not require a Fly mount for local development" do
    assert :ok ==
             Storage.check(
               fly_app_name: nil,
               repo_config: [database: "/tmp/custyard.db"],
               mountinfo: @unmounted
             )
  end

  test "reports a second machine, which would hold a second SQLite database" do
    assert {:error, :multiple_machines, detail} = check(machine_ids: @two_machines)

    assert detail =~ ~r/has 2 machines.*fly scale count 1/s
    assert detail =~ ~r/keeps its SQLite database\s+under \/data/
    assert detail =~ "fly scale count 1 -a YOUR_APP_NAME"
    assert detail =~ ~r/remote database.*lifts the limit/
    refute detail =~ "uploads"
    refute detail =~ "080e94edf34038"
    refute detail =~ "d8d0066f561338"

    assert_raise RuntimeError, ~r/has 2 machines/, fn ->
      Storage.validate_fly_storage!(Keyword.put(@fly, :machine_ids, @two_machines))
    end
  end

  test "a remote database needs no mount and lifts the single-machine limit" do
    for {_kind, repo_config} <- @remote_databases do
      overrides = [repo_config: repo_config, sqlite_path: "/nonexistent"]

      assert :ok == check(overrides)
      assert :ok == check(overrides ++ [mountinfo: @unmounted])
      assert :ok == check(overrides ++ [machine_ids: @two_machines])
      assert :ok == check(overrides ++ [mountinfo: @unmounted, machine_ids: @two_machines])

      # Neither the mount table nor the machine list is consulted.
      log =
        capture_log(fn ->
          assert :ok ==
                   check(overrides ++ [mountinfo: {:error, :enoent}, machine_ids: :unknown])

          assert :ok ==
                   Storage.validate_fly_storage!(
                     Keyword.merge(@fly, overrides ++ [mountinfo: @unmounted])
                   )
        end)

      refute log =~ "fly_mount_verification_failed"
      refute log =~ "fly_machine_count_unknown"
    end
  end

  test "a path left over from SQLite does not make a remote database local" do
    turso = [turso_url: "libsql://custyard-acme.turso.io", database: "/tmp/custyard.db"]
    postgres = [url: "postgres://localhost/custyard", database: "/tmp/custyard.db"]

    for repo_config <- [turso, postgres] do
      assert :ok ==
               check(
                 repo_config: repo_config,
                 sqlite_path: "/nonexistent",
                 mountinfo: @unmounted,
                 machine_ids: @two_machines
               )
    end
  end

  @tag :tmp_dir
  test "on Turso, warns while the old SQLite file is still on the volume", %{tmp_dir: dir} do
    sqlite = Path.join(dir, "custyard.db")

    validate = fn ->
      assert :ok ==
               check(
                 repo_config: [turso_url: "libsql://custyard-acme.turso.io"],
                 sqlite_path: sqlite
               )
    end

    refute capture_log(validate) =~ "unused_local_database_detected"

    File.write!(sqlite, "")
    log = capture_log(validate)
    assert log =~ "unused_local_database_detected"
    refute log =~ sqlite
  end

  test "continues with a warning when the machine count cannot be determined" do
    assert capture_log(fn -> assert :ok == check(machine_ids: :unknown) end) =~
             "fly_machine_count_unknown"
  end

  describe "Bunny hosting" do
    test "passes on the Bunny remote database with no volume" do
      assert :ok == Storage.check(@bunny)
      assert :ok == Storage.validate!(@bunny)

      # Nothing is mounted, and the mount table is not even readable.
      assert :ok == Storage.check(@bunny ++ [mountinfo: @unmounted])
      assert :ok == Storage.check(@bunny ++ [mountinfo: {:error, :enoent}])
    end

    test "refuses a local database and any other remote one" do
      for repo_config <- [
            [database: "/data/custyard.db"],
            [database: "/tmp/" <> @canary],
            @remote_databases[:turso],
            @remote_databases[:postgres],
            []
          ] do
        opts = [provider: :bunny, repo_config: repo_config, mountinfo: @mounted]

        assert {:error, :bunny_database_required, detail} = Storage.check(opts)

        assert detail ==
                 "Bunny storage requires the configured Bunny remote database; refusing local fallback"

        assert_raise RuntimeError, ~r/requires the configured Bunny remote database/, fn ->
          Storage.validate!(opts)
        end
      end
    end
  end

  describe "provider selection" do
    test "local checks nothing, whatever else is configured" do
      assert :ok ==
               Storage.check(
                 provider: :local,
                 repo_config: [database: "/tmp/custyard.db"],
                 mountinfo: @unmounted,
                 machine_ids: @two_machines
               )
    end

    test "an unknown provider is refused" do
      assert {:error, :provider_unsupported, "STORAGE_PROVIDER must be local, fly or bunny"} ==
               Storage.check(Keyword.put(@bunny, :provider, :invalid))

      assert_raise RuntimeError, "STORAGE_PROVIDER must be local, fly or bunny", fn ->
        Storage.validate!(Keyword.put(@bunny, :provider, :invalid))
      end
    end

    test "the Fly-only entry point never runs the Bunny check" do
      opts = [provider: :bunny, repo_config: [database: "/data/custyard.db"]]

      assert :ok == Storage.validate_fly_storage!(Keyword.put(opts, :fly_app_name, nil))
    end

    test "explicit Fly selection cannot bypass mount checks without automatic platform metadata" do
      assert_raise RuntimeError, ~r/no mounted volume/, fn ->
        Storage.validate!(
          provider: :fly,
          fly_app_name: nil,
          repo_config: [database: "/data/custyard.db"],
          mountinfo: @unmounted
        )
      end
    end
  end

  describe "mounted?/2" do
    test "tells a path on a mount from one on the root filesystem" do
      assert Storage.mounted?("/data/custyard.db", {:ok, @mounted}) == true
      assert Storage.mounted?("/data", {:ok, @mounted}) == true
      assert Storage.mounted?("/data/custyard.db", {:ok, @unmounted}) == false
      assert Storage.mounted?("/database/custyard.db", {:ok, @mounted}) == false
      assert Storage.mounted?("/tmp/custyard.db", {:ok, @mounted <> @unmounted}) == false
    end

    test "is unknown without mountinfo" do
      assert Storage.mounted?("/data/custyard.db", {:error, :enoent}) == nil
    end
  end
end
