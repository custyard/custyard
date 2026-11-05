defmodule Custyard.Release.Volume do
  @moduledoc """
  Maintenance-only recovery of uploads and attachments on the Bunny file volume.
  Snapshots are directories with a SHA-256 manifest, not database backups. Copy
  them off the node and encrypt them using the deployment's backup tooling.
  Stop the server before invoking these commands; this module never starts it.
  """

  alias Custyard.Storage

  @usage """
  Usage: bin/data-volume init | backup DIRECTORY | restore DIRECTORY

  All commands require MAINTENANCE_MODE=true and the configured DATA_VOLUME_ID.
  init explicitly adopts a new empty mounted volume. backup writes a new
  directory outside /data. restore verifies a snapshot and fills an initialized,
  empty volume with the same identity. Neither command transfers the database.
  """

  def main(args) do
    run_cli(args)
  rescue
    _error ->
      IO.puts(
        :stderr,
        "File-volume command failed; verify maintenance mode, volume identity and snapshot integrity."
      )

      :error
  end

  defp run_cli(args) do
    case args do
      ["init"] ->
        require_maintenance!([])
        Storage.initialize_volume!()
        IO.puts("File volume initialized.")

      ["backup", destination] ->
        backup!(destination)
        IO.puts("File snapshot written and verified.")

      ["restore", source] ->
        restore!(source)
        IO.puts("File snapshot restored and verified.")

      ["help"] ->
        IO.puts(@usage)

      _ ->
        raise ArgumentError, @usage
    end
  end

  @doc "Copies only uploads and attachments into a new verified snapshot directory."
  def backup!(destination, opts \\ []) do
    require_maintenance!(opts)
    Storage.validate!(Keyword.put(opts, :provider, :bunny))
    data_dir = Keyword.get(opts, :data_dir, "/data")
    destination = external_directory!(destination, data_dir)
    roots = roots(opts)
    manifest = manifest(roots, identity(opts))
    require_absent!(destination)
    File.mkdir!(destination)
    File.chmod!(destination, 0o700)

    for {label, source} <- roots,
        do: copy_tree!(source, Path.join(destination, label))

    unless manifest(backup_roots(destination), identity(opts)) == manifest,
      do: raise("File snapshot changed during backup; keep the app stopped and retry")

    File.write!(Path.join(destination, "manifest.json"), Jason.encode!(manifest))
    File.chmod!(Path.join(destination, "manifest.json"), 0o600)
    :ok
  end

  @doc "Restores a verified snapshot into empty upload and attachment directories."
  def restore!(source, opts \\ []) do
    require_maintenance!(opts)
    Storage.validate!(Keyword.put(opts, :provider, :bunny))
    data_dir = Keyword.get(opts, :data_dir, "/data")
    source = external_directory!(source, data_dir)
    expected = read_manifest!(source)

    unless expected["volume_id"] == identity(opts),
      do: raise("File snapshot identity does not match DATA_VOLUME_ID")

    unless Enum.sort(File.ls!(source)) == ["attachments", "manifest.json", "uploads"] and
             manifest(backup_roots(source), identity(opts)) == expected,
           do: raise("File snapshot contents do not match the checksum manifest")

    roots = roots(opts)

    unless Enum.all?(roots, fn {_, directory} -> File.ls!(directory) == [] end),
      do: raise("Restore requires empty upload and attachment directories")

    guard = Path.join(data_dir, ".custyard-restore-in-progress")
    File.write!(guard, "Do not start Custyard until restoration is complete.\n", [:exclusive])
    stage = Path.join(data_dir, ".custyard-restore-stage-" <> random_id())
    File.mkdir!(stage)
    File.chmod!(stage, 0o700)

    # Keep the guard on every failure, including interruption between renames.
    # Storage refuses startup until an operator has inspected the partial restore.
    for {label, _} <- roots,
        do: copy_tree!(Path.join(source, label), Path.join(stage, label))

    unless manifest(backup_roots(stage), identity(opts)) == expected,
      do: raise("Staged restore does not match the checksum manifest")

    for {label, destination} <- roots do
      File.rmdir!(destination)
      File.rename!(Path.join(stage, label), destination)
    end

    File.rmdir!(stage)
    File.rm!(guard)
    :ok
  end

  defp require_maintenance!(opts) do
    unless Keyword.get(opts, :maintenance, System.get_env("MAINTENANCE_MODE") == "true"),
      do: raise("Stop the app and set MAINTENANCE_MODE=true before file-volume maintenance")
  end

  defp identity(opts),
    do: Keyword.get(opts, :data_volume_id, Application.get_env(:custyard, :data_volume_id))

  defp roots(opts) do
    roots = [
      {"uploads", Keyword.get(opts, :upload_dir, Application.get_env(:custyard, :upload_dir))},
      {"attachments",
       Keyword.get(opts, :attachment_dir, Application.get_env(:custyard, :attachment_dir))}
    ]

    [{_, uploads}, {_, attachments}] = roots

    if uploads == attachments or String.starts_with?(uploads, attachments <> "/") or
         String.starts_with?(attachments, uploads <> "/"),
       do: raise("Upload and attachment directories must not overlap")

    roots
  end

  defp backup_roots(directory),
    do: Enum.map(["uploads", "attachments"], &{&1, Path.join(directory, &1)})

  defp manifest(roots, identity) do
    entries =
      for {label, directory} <- roots,
          {relative, metadata} <- scan!(directory, label),
          into: %{},
          do: {relative, metadata}

    %{"version" => 1, "volume_id" => identity, "entries" => entries}
  end

  defp scan!(directory, relative) do
    require_type!(directory, :directory)

    [{relative, %{"type" => "directory"}}] ++
      Enum.flat_map(File.ls!(directory) |> Enum.sort(), fn name ->
        path = Path.join(directory, name)
        child = Path.join(relative, name)

        case File.lstat!(path) do
          %{type: :directory} ->
            scan!(path, child)

          %{type: :regular, size: size} ->
            [{child, %{"type" => "file", "size" => size, "sha256" => checksum(path)}}]

          _ ->
            raise "File snapshots refuse symbolic links and special files"
        end
      end)
  end

  defp checksum(path) do
    path
    |> File.stream!([], 65_536)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp copy_tree!(source, destination) do
    require_type!(source, :directory)
    File.mkdir!(destination)
    File.chmod!(destination, 0o700)

    for name <- File.ls!(source) do
      from = Path.join(source, name)
      to = Path.join(destination, name)

      case File.lstat!(from) do
        %{type: :directory} ->
          copy_tree!(from, to)

        %{type: :regular} ->
          File.cp!(from, to)
          File.chmod!(to, 0o600)

        _ ->
          raise "File snapshots refuse symbolic links and special files"
      end
    end
  end

  defp read_manifest!(source) do
    path = Path.join(source, "manifest.json")
    require_type!(path, :regular)

    if File.stat!(path).size > 16_777_216,
      do: raise("File snapshot manifest exceeds the supported size")

    case Jason.decode!(File.read!(path)) do
      %{"version" => 1, "volume_id" => id, "entries" => entries} = manifest
      when is_binary(id) and is_map(entries) ->
        manifest

      _ ->
        raise "Unsupported file snapshot manifest"
    end
  end

  defp external_directory!(directory, data_dir) do
    directory = Path.expand(directory)
    data_dir = Path.expand(data_dir)

    if directory == data_dir or String.starts_with?(directory, data_dir <> "/"),
      do: raise("File snapshot directory must be outside the data volume")

    # No path component may redirect the operation through a symbolic link.
    directory
    |> Path.split()
    |> tl()
    |> Enum.reduce("/", fn segment, parent ->
      current = Path.join(parent, segment)

      case File.lstat(current) do
        {:ok, %{type: :directory}} -> :ok
        {:error, :enoent} when current == directory -> :ok
        _ -> raise "File snapshot paths require existing directories without symbolic links"
      end

      current
    end)
  end

  defp require_type!(path, type) do
    unless match?({:ok, %{type: ^type}}, File.lstat(path)),
      do: raise("File snapshots refuse missing paths, symbolic links and special files")
  end

  defp require_absent!(path) do
    unless File.lstat(path) == {:error, :enoent},
      do: raise("File snapshot destination already exists")
  end

  defp random_id, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
end
