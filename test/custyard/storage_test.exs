defmodule Custyard.StorageTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Custyard.Storage

  @mounted "36 28 0:29 / /data rw,relatime - ext4 /dev/vdb rw\n"
  @unmounted "35 28 0:28 / / rw,relatime - overlay overlay rw\n"
  @one_machine {:ok, ["080e94edf34038"]}
  @canary "private-person@example.test-credential\r\nFORGED EVENT"

  @fly [
    fly_app_name: "custyard",
    repo_config: [database: "/data/custyard.db"],
    upload_dir: "/data/uploads",
    attachment_dir: "/data/attachments",
    mountinfo: @mounted,
    machine_ids: @one_machine
  ]

  defp check(overrides), do: Storage.check(Keyword.merge(@fly, overrides))

  test "allows SQLite and uploads on a mounted Fly volume" do
    assert :ok == check([])
    assert :ok == Storage.validate_fly_storage!(@fly)
  end

  test "reports a missing volume even when /data exists in the image" do
    assert {:error, :volume_missing, detail} = check(mountinfo: @unmounted)
    assert detail =~ "no mounted volume at /data"

    assert_raise RuntimeError, ~r/no mounted volume at \/data/, fn ->
      Storage.validate_fly_storage!(Keyword.put(@fly, :mountinfo, @unmounted))
    end
  end

  test "reports paths outside the Fly volume" do
    assert {:error, :volume_missing, "DATABASE_PATH must point inside" <> _} =
             check(repo_config: [database: "/tmp/custyard.db"])

    assert {:error, :volume_missing, "ATTACHMENT_DIR must point inside" <> _} =
             check(attachment_dir: "/app/priv/attachments")

    assert {:error, :volume_missing, "UPLOAD_DIR must point inside" <> _} =
             check(upload_dir: "/tmp/uploads")

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
               upload_dir: "/tmp/uploads",
               mountinfo: @unmounted
             )
  end

  test "reports a second machine, which would hold a second SQLite database" do
    assert {:error, :multiple_machines, detail} =
             check(machine_ids: {:ok, ["080e94edf34038", "d8d0066f561338"]})

    assert detail =~ ~r/has 2 machines.*fly scale count 1/s
    assert detail =~ "fly scale count 1 -a YOUR_APP_NAME"
    refute detail =~ "080e94edf34038"
    refute detail =~ "d8d0066f561338"

    assert_raise RuntimeError, ~r/has 2 machines/, fn ->
      Storage.validate_fly_storage!(
        Keyword.put(@fly, :machine_ids, {:ok, ["080e94edf34038", "d8d0066f561338"]})
      )
    end
  end

  test "reports a second machine when the database is remote, since files stay on the volume" do
    assert {:error, :multiple_machines, detail} =
             check(
               repo_config: [url: "postgres://localhost/custyard"],
               machine_ids: {:ok, ["080e94edf34038", "d8d0066f561338"]}
             )

    assert detail =~ ~r/has 2 machines.*keeps\s+uploads and inbound attachments under \/data/s
    assert detail =~ ~r/Turso or PostgreSQL database does not lift the limit/
    refute detail =~ "SQLite"
  end

  test "allows one machine when the database is remote" do
    assert :ok == check(repo_config: [url: "postgres://localhost/custyard"])
  end

  test "a Turso database is not on the volume, but uploads still are" do
    # A leftover :database path does not make it local.
    turso = [turso_url: "libsql://custyard-acme.turso.io", database: "/tmp/custyard.db"]

    assert :ok == check(repo_config: turso)

    assert {:error, :multiple_machines, detail} =
             check(repo_config: turso, machine_ids: {:ok, ["080e94edf34038", "d8d0066f561338"]})

    assert detail =~ ~r/keeps\s+uploads and inbound attachments under \/data/
    refute detail =~ "SQLite"

    assert {:error, :volume_missing, _} = check(repo_config: turso, mountinfo: @unmounted)
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
