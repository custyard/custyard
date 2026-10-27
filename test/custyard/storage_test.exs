defmodule Custyard.StorageTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Custyard.Storage

  @mounted "36 28 0:29 / /data rw,relatime - ext4 /dev/vdb rw\n"
  @unmounted "35 28 0:28 / / rw,relatime - overlay overlay rw\n"
  @one_machine {:ok, ["080e94edf34038"]}

  test "allows SQLite and uploads on a mounted Fly volume" do
    assert :ok ==
             Storage.validate_fly_storage!(
               fly_app_name: "custyard",
               repo_config: [database: "/data/custyard.db"],
               upload_dir: "/data/uploads",
               attachment_dir: "/data/attachments",
               mountinfo: @mounted,
               machine_ids: @one_machine
             )
  end

  test "rejects a missing volume even when /data exists in the image" do
    assert_raise RuntimeError, ~r/no mounted volume at \/data/, fn ->
      Storage.validate_fly_storage!(
        fly_app_name: "custyard",
        repo_config: [database: "/data/custyard.db"],
        upload_dir: "/data/uploads",
        attachment_dir: "/data/attachments",
        mountinfo: @unmounted
      )
    end
  end

  test "rejects paths outside the Fly volume" do
    assert_raise RuntimeError, ~r/DATABASE_PATH must point inside/, fn ->
      Storage.validate_fly_storage!(
        fly_app_name: "custyard",
        repo_config: [database: "/tmp/custyard.db"],
        upload_dir: "/data/uploads",
        attachment_dir: "/data/attachments",
        mountinfo: @mounted
      )
    end

    assert_raise RuntimeError, ~r/ATTACHMENT_DIR must point inside/, fn ->
      Storage.validate_fly_storage!(
        fly_app_name: "custyard",
        repo_config: [database: "/data/custyard.db"],
        upload_dir: "/data/uploads",
        attachment_dir: "/app/priv/attachments",
        mountinfo: @mounted
      )
    end

    assert_raise RuntimeError, ~r/UPLOAD_DIR must point inside/, fn ->
      Storage.validate_fly_storage!(
        fly_app_name: "custyard",
        repo_config: [database: "/data/custyard.db"],
        upload_dir: "/tmp/uploads",
        mountinfo: @mounted
      )
    end
  end

  test "does not require a Fly mount for local development" do
    assert :ok ==
             Storage.validate_fly_storage!(
               fly_app_name: nil,
               repo_config: [database: "/tmp/custyard.db"],
               upload_dir: "/tmp/uploads",
               mountinfo: @unmounted
             )
  end

  test "rejects a second machine, which would hold a second SQLite database" do
    assert_raise RuntimeError, ~r/has 2 machines.*fly scale count 1/s, fn ->
      Storage.validate_fly_storage!(
        fly_app_name: "custyard",
        repo_config: [database: "/data/custyard.db"],
        upload_dir: "/data/uploads",
        attachment_dir: "/data/attachments",
        mountinfo: @mounted,
        machine_ids: {:ok, ["080e94edf34038", "d8d0066f561338"]}
      )
    end
  end

  test "rejects a second machine when the database is remote, since files stay on the volume" do
    error =
      assert_raise RuntimeError, fn ->
        Storage.validate_fly_storage!(
          fly_app_name: "custyard",
          repo_config: [url: "postgres://localhost/custyard"],
          upload_dir: "/data/uploads",
          attachment_dir: "/data/attachments",
          mountinfo: @mounted,
          machine_ids: {:ok, ["080e94edf34038", "d8d0066f561338"]}
        )
      end

    assert error.message =~
             ~r/has 2 machines.*keeps\s+uploads and inbound attachments under \/data/s

    assert error.message =~ ~r/Turso or PostgreSQL database does not lift the limit/
    refute error.message =~ "SQLite"
  end

  test "allows one machine when the database is remote" do
    assert :ok ==
             Storage.validate_fly_storage!(
               fly_app_name: "custyard",
               repo_config: [url: "postgres://localhost/custyard"],
               upload_dir: "/data/uploads",
               attachment_dir: "/data/attachments",
               mountinfo: @mounted,
               machine_ids: @one_machine
             )
  end

  test "a Turso database is not on the volume, but uploads still are" do
    # A leftover :database path does not make it local.
    turso = [turso_url: "libsql://custyard-acme.turso.io", database: "/tmp/custyard.db"]

    assert :ok ==
             Storage.validate_fly_storage!(
               fly_app_name: "custyard",
               repo_config: turso,
               upload_dir: "/data/uploads",
               attachment_dir: "/data/attachments",
               mountinfo: @mounted,
               machine_ids: @one_machine
             )

    error =
      assert_raise RuntimeError, fn ->
        Storage.validate_fly_storage!(
          fly_app_name: "custyard",
          repo_config: turso,
          upload_dir: "/data/uploads",
          attachment_dir: "/data/attachments",
          mountinfo: @mounted,
          machine_ids: {:ok, ["080e94edf34038", "d8d0066f561338"]}
        )
      end

    assert error.message =~ ~r/keeps\s+uploads and inbound attachments under \/data/
    refute error.message =~ "SQLite"

    assert_raise RuntimeError, ~r/no mounted volume at \/data/, fn ->
      Storage.validate_fly_storage!(
        fly_app_name: "custyard",
        repo_config: turso,
        upload_dir: "/data/uploads",
        attachment_dir: "/data/attachments",
        mountinfo: @unmounted
      )
    end
  end

  @tag :tmp_dir
  test "on Turso, warns while the old SQLite file is still on the volume", %{tmp_dir: dir} do
    sqlite = Path.join(dir, "custyard.db")

    validate = fn ->
      Storage.validate_fly_storage!(
        fly_app_name: "custyard",
        repo_config: [turso_url: "libsql://custyard-acme.turso.io"],
        upload_dir: "/data/uploads",
        attachment_dir: "/data/attachments",
        mountinfo: @mounted,
        machine_ids: @one_machine,
        sqlite_path: sqlite
      )
    end

    refute capture_log(validate) =~ "still has"

    File.write!(sqlite, "")
    assert capture_log(validate) =~ "#{sqlite} still has a SQLite database"
  end

  test "boots with a warning when the machine count cannot be determined" do
    assert :ok ==
             Storage.validate_fly_storage!(
               fly_app_name: "custyard",
               repo_config: [database: "/data/custyard.db"],
               upload_dir: "/data/uploads",
               attachment_dir: "/data/attachments",
               mountinfo: @mounted,
               machine_ids: :unknown
             )
  end
end
