defmodule Custyard.StorageTest do
  use ExUnit.Case, async: true

  alias Custyard.Storage

  @mounted "36 28 0:29 / /data rw,relatime - ext4 /dev/vdb rw\n"
  @unmounted "35 28 0:28 / / rw,relatime - overlay overlay rw\n"

  test "allows SQLite and uploads on a mounted Fly volume" do
    assert :ok ==
             Storage.validate_fly_storage!(
               fly_app_name: "custyard",
               repo_config: [database: "/data/custyard.db"],
               upload_dir: "/data/uploads",
               mountinfo: @mounted
             )
  end

  test "rejects a missing volume even when /data exists in the image" do
    assert_raise RuntimeError, ~r/no mounted volume at \/data/, fn ->
      Storage.validate_fly_storage!(
        fly_app_name: "custyard",
        repo_config: [database: "/data/custyard.db"],
        upload_dir: "/data/uploads",
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
end
