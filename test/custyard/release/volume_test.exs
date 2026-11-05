defmodule Custyard.Release.VolumeTest do
  use ExUnit.Case, async: true

  alias Custyard.Release.Volume

  test "CLI failures do not print caller paths or filesystem exceptions" do
    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert Volume.main(["restore", "/private/customer-filename-secret"]) == :error
      end)

    assert output =~ "File-volume command failed"
    refute output =~ "customer-filename-secret"
    refute output =~ "File.Error"
  end

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    # Resolve macOS's /var and /tmp aliases so path safety tests exercise real
    # directories rather than a host-provided symbolic-link ancestor.
    tmp_dir = tmp_dir |> Path.expand() |> String.replace_prefix("/var/", "/private/var/")
    data_dir = Path.join(tmp_dir, "data")
    uploads = Path.join(data_dir, "uploads")
    attachments = Path.join(data_dir, "attachments")
    File.mkdir_p!(uploads)
    File.mkdir_p!(attachments)
    File.write!(Path.join(data_dir, ".custyard-volume"), "test-volume\n")

    opts = [
      maintenance: true,
      data_dir: data_dir,
      data_volume_id: "test-volume",
      upload_dir: uploads,
      attachment_dir: attachments,
      repo_config: [turso_url: "https://test.invalid", turso_provider: :bunny],
      mountinfo: "1 0 0:1 / #{data_dir} rw - ext4 test rw\n"
    ]

    %{
      opts: opts,
      data_dir: data_dir,
      uploads: uploads,
      attachments: attachments,
      tmp_dir: tmp_dir
    }
  end

  test "backups round-trip nested files and empty directories with checksums", context do
    File.mkdir!(Path.join(context.uploads, "empty"))
    File.mkdir!(Path.join(context.attachments, "private"))
    File.write!(Path.join(context.uploads, "logo.png"), <<0, 1, 255>>)
    File.write!(Path.join(context.attachments, "private/mail.eml"), "message\n")
    snapshot = Path.join(context.tmp_dir, "snapshot")

    assert :ok = Volume.backup!(snapshot, context.opts)
    manifest = Jason.decode!(File.read!(Path.join(snapshot, "manifest.json")))
    assert manifest["volume_id"] == "test-volume"

    assert manifest["entries"]["attachments/private/mail.eml"]["sha256"] ==
             Base.encode16(:crypto.hash(:sha256, "message\n"), case: :lower)

    File.rm_rf!(context.uploads)
    File.rm_rf!(context.attachments)
    File.mkdir!(context.uploads)
    File.mkdir!(context.attachments)

    assert :ok = Volume.restore!(snapshot, context.opts)
    assert File.read!(Path.join(context.uploads, "logo.png")) == <<0, 1, 255>>
    assert File.read!(Path.join(context.attachments, "private/mail.eml")) == "message\n"
    assert File.dir?(Path.join(context.uploads, "empty"))
    refute File.exists?(Path.join(context.data_dir, ".custyard-restore-in-progress"))
  end

  test "refuses maintenance without a stopped-app declaration", context do
    assert_raise RuntimeError, ~r/MAINTENANCE_MODE/, fn ->
      Volume.backup!(
        Path.join(context.tmp_dir, "snapshot"),
        Keyword.put(context.opts, :maintenance, false)
      )
    end
  end

  test "refuses symlinks without reading the target", context do
    File.write!(Path.join(context.tmp_dir, "outside-secret"), "not-for-snapshot")

    File.ln_s!(
      Path.join(context.tmp_dir, "outside-secret"),
      Path.join(context.attachments, "bad")
    )

    assert_raise RuntimeError, ~r/symbolic links/, fn ->
      Volume.backup!(Path.join(context.tmp_dir, "snapshot"), context.opts)
    end

    refute File.exists?(Path.join(context.tmp_dir, "snapshot"))
  end

  test "refuses backup destinations on the same data volume or existing paths", context do
    assert_raise RuntimeError, ~r/outside the data volume/, fn ->
      Volume.backup!(Path.join(context.data_dir, "backup"), context.opts)
    end

    assert_raise RuntimeError, ~r/already exists/, fn ->
      Volume.backup!(context.tmp_dir, context.opts)
    end
  end

  test "refuses symbolic-link parents for backup destinations", context do
    File.ln_s!(context.data_dir, Path.join(context.tmp_dir, "alias"))

    assert_raise RuntimeError, ~r/without symbolic links/, fn ->
      Volume.backup!(Path.join(context.tmp_dir, "alias/backup"), context.opts)
    end
  end

  test "corrupt snapshots cannot mutate the file volume", context do
    snapshot = Path.join(context.tmp_dir, "snapshot")
    File.write!(Path.join(context.attachments, "mail.eml"), "original")
    Volume.backup!(snapshot, context.opts)
    File.rm!(Path.join(context.attachments, "mail.eml"))
    File.write!(Path.join(snapshot, "attachments/mail.eml"), "tampered")

    assert_raise RuntimeError, ~r/checksum manifest/, fn ->
      Volume.restore!(snapshot, context.opts)
    end

    assert File.ls!(context.attachments) == []
    refute File.exists?(Path.join(context.data_dir, ".custyard-restore-in-progress"))
  end

  test "snapshots from a different volume and nonempty destinations are refused", context do
    snapshot = Path.join(context.tmp_dir, "snapshot")
    File.write!(Path.join(context.uploads, "existing"), "keep")
    Volume.backup!(snapshot, context.opts)

    assert_raise RuntimeError, ~r/empty upload and attachment/, fn ->
      Volume.restore!(snapshot, context.opts)
    end

    manifest_file = Path.join(snapshot, "manifest.json")
    manifest = Jason.decode!(File.read!(manifest_file)) |> Map.put("volume_id", "another-volume")
    File.write!(manifest_file, Jason.encode!(manifest))

    assert_raise RuntimeError, ~r/identity/, fn ->
      Volume.restore!(snapshot, context.opts)
    end

    assert File.read!(Path.join(context.uploads, "existing")) == "keep"
  end

  test "manifest paths are never used as filesystem paths", context do
    snapshot = Path.join(context.tmp_dir, "snapshot")
    Volume.backup!(snapshot, context.opts)
    manifest_file = Path.join(snapshot, "manifest.json")
    manifest = Jason.decode!(File.read!(manifest_file))
    manifest = put_in(manifest, ["entries", "../../escaped"], %{"type" => "directory"})
    File.write!(manifest_file, Jason.encode!(manifest))

    assert_raise RuntimeError, ~r/checksum manifest/, fn ->
      Volume.restore!(snapshot, context.opts)
    end

    refute File.exists?(Path.join(context.tmp_dir, "escaped"))
  end
end
