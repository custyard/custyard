defmodule Custyard.BunnyStorageTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  alias Custyard.Storage

  @repo [turso_url: "libsql://database.example", turso_provider: :bunny]

  setup %{tmp_dir: directory} do
    opts = [
      provider: :bunny,
      repo_config: @repo,
      data_dir: directory,
      data_volume_id: "test-volume",
      upload_dir: Path.join(directory, "uploads"),
      attachment_dir: Path.join(directory, "attachments"),
      mountinfo: "36 28 0:29 / #{directory} rw,relatime - ext4 /dev/vdb rw\n"
    ]

    {:ok, opts: opts}
  end

  @tag :tmp_dir
  test "explicit initialization is idempotent and normal boot verifies the marker", %{opts: opts} do
    assert :ok == Storage.initialize_volume!(opts)
    assert :ok == Storage.initialize_volume!(opts)
    assert :ok == Storage.validate!(opts)
    assert File.read!(Path.join(opts[:data_dir], ".custyard-volume")) == "test-volume\n"
    assert File.ls!(opts[:upload_dir]) == []
    assert File.ls!(opts[:attachment_dir]) == []
  end

  @tag :tmp_dir
  test "normal boot refuses an uninitialized replacement without creating marker or files", %{
    opts: opts
  } do
    assert_raise RuntimeError, ~r/File-volume marker is missing/, fn ->
      Storage.validate!(opts)
    end

    assert File.ls!(opts[:data_dir]) == []
  end

  test "normal boot does not recreate missing data directories on an identified volume", %{
    opts: opts
  } do
    Storage.initialize_volume!(opts)
    File.rmdir!(opts[:upload_dir])
    assert_raise RuntimeError, ~r/UPLOAD_DIR is missing/, fn -> Storage.validate!(opts) end
    refute File.exists?(opts[:upload_dir])
  end

  @tag :tmp_dir
  test "both initialization and normal boot reject a missing mount", %{opts: opts} do
    opts = Keyword.put(opts, :mountinfo, "35 28 0:28 / / rw - overlay overlay rw\n")

    for command <- [&Storage.initialize_volume!/1, &Storage.validate!/1] do
      assert_raise RuntimeError, ~r/mounted file volume/, fn -> command.(opts) end
    end

    assert File.ls!(opts[:data_dir]) == []
  end

  @tag :tmp_dir
  test "initialization refuses existing unmarked data and marker mismatches", %{opts: opts} do
    sentinel = Path.join(opts[:data_dir], "precious-data")
    File.write!(sentinel, "retained")

    assert_raise RuntimeError, ~r/nonempty/, fn -> Storage.initialize_volume!(opts) end
    assert File.read!(sentinel) == "retained"

    File.rm!(sentinel)
    Storage.initialize_volume!(opts)
    other = Keyword.put(opts, :data_volume_id, "different-volume")
    assert_raise RuntimeError, ~r/does not match/, fn -> Storage.initialize_volume!(other) end
    assert_raise RuntimeError, ~r/does not match/, fn -> Storage.validate!(other) end
  end

  @tag :tmp_dir
  test "Bunny host refuses a local database even with a valid mounted volume", %{opts: opts} do
    Storage.initialize_volume!(opts)

    for config <- [[database: "/data/custyard.db"], [turso_url: "libsql://database.example"]] do
      assert_raise RuntimeError, ~r/requires the configured Bunny remote database/, fn ->
        Storage.validate!(Keyword.put(opts, :repo_config, config))
      end
    end
  end

  @tag :tmp_dir
  test "missing or malformed identity cannot initialize a volume", %{opts: opts} do
    for identity <- [nil, "", "../volume", "private-person@example.test\nFORGED"] do
      error =
        assert_raise RuntimeError, ~r/DATA_VOLUME_ID/, fn ->
          Storage.initialize_volume!(Keyword.put(opts, :data_volume_id, identity))
        end

      refute error.message =~ "private-person"
    end

    assert File.ls!(opts[:data_dir]) == []
  end

  @tag :tmp_dir
  test "paths escaping the mounted volume are refused before creating directories", %{opts: opts} do
    Storage.initialize_volume!(opts)

    for variable <- [:upload_dir, :attachment_dir] do
      escaped = Path.join(opts[:data_dir], "../private-path")

      error =
        assert_raise RuntimeError, ~r/must point inside/, fn ->
          Storage.validate!(Keyword.put(opts, variable, escaped))
        end

      refute error.message =~ "private-path"
    end
  end

  @tag :tmp_dir
  test "symbolic-link marker and directories cannot bypass containment", %{opts: opts} do
    Storage.initialize_volume!(opts)
    marker = Path.join(opts[:data_dir], ".custyard-volume")
    target = Path.join(opts[:data_dir], "other-marker")
    File.rename!(marker, target)
    File.ln_s!(target, marker)
    assert_raise RuntimeError, ~r/File-volume marker/, fn -> Storage.validate!(opts) end

    File.rm!(marker)
    File.rename!(target, marker)
    File.rmdir!(opts[:upload_dir])
    File.ln_s!(opts[:attachment_dir], opts[:upload_dir])
    assert_raise RuntimeError, ~r/without symbolic links/, fn -> Storage.validate!(opts) end
  end

  @tag :tmp_dir
  test "an interrupted restore blocks both initialization and startup", %{opts: opts} do
    Storage.initialize_volume!(opts)
    flag = Path.join(opts[:data_dir], ".custyard-restore-in-progress")
    File.write!(flag, "incomplete")

    for command <- [&Storage.initialize_volume!/1, &Storage.validate!/1] do
      assert_raise RuntimeError, ~r/restoration is incomplete/, fn -> command.(opts) end
    end
  end

  @tag :tmp_dir
  test "mounted but read-only upload storage fails before opening the database", %{opts: opts} do
    Storage.initialize_volume!(opts)
    File.chmod!(opts[:upload_dir], 0o500)
    on_exit(fn -> File.chmod(opts[:upload_dir], 0o700) end)

    assert_raise RuntimeError, ~r/UPLOAD_DIR must be writable/, fn -> Storage.validate!(opts) end
  end

  test "explicit Fly selection cannot bypass mount checks without automatic platform metadata" do
    assert_raise RuntimeError, ~r/no mounted volume/, fn ->
      Storage.validate!(
        provider: :fly,
        fly_app_name: nil,
        repo_config: [database: "/data/custyard.db"],
        upload_dir: "/data/uploads",
        attachment_dir: "/data/attachments",
        mountinfo: "35 28 0:28 / / rw - overlay overlay rw\n"
      )
    end
  end
end
