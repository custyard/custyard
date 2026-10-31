defmodule Custyard.Storage do
  @moduledoc """
  Verifies that Fly's local database, uploads and attachments live on a mounted
  volume attached to the app's only machine.

  A remote database (Turso over `libsql://`, or PostgreSQL) is not on the
  volume, so its path is not checked. Uploads and attachments still are, so
  the app still runs on one machine.

  The check runs before the Repo and release migrations start, so a missing
  volume cannot silently create a fresh database on the container filesystem,
  and a second machine cannot silently create a second copy of what the volume
  stores.
  """

  alias Custyard.Repo.Adapter

  require Custyard.Log, as: Log

  @data_dir "/data"

  # Internal Fly DNS, so a lookup should answer in well under a second. Boot
  # continues when it does not: an unreachable resolver is not evidence of a
  # second machine.
  @machine_dns_timeout 2_000

  def validate_fly_storage!(opts \\ []) do
    if Keyword.get(opts, :fly_app_name, System.get_env("FLY_APP_NAME")) do
      repo_config =
        Keyword.get(opts, :repo_config, Application.get_env(:custyard, Custyard.Repo, []))

      validate_fly_paths!(repo_config, opts)
      if Adapter.turso?(repo_config), do: warn_about_left_behind_sqlite(opts)
    end

    :ok
  end

  defp validate_fly_paths!(repo_config, opts) do
    upload_dir = Keyword.get(opts, :upload_dir, Application.get_env(:custyard, :upload_dir))

    attachment_dir =
      Keyword.get(opts, :attachment_dir, Application.get_env(:custyard, :attachment_dir))

    database_path = Keyword.get(repo_config, :database)
    local_database? = local_database?(repo_config)

    if local_database?, do: require_data_path!(database_path, "DATABASE_PATH")
    if is_binary(upload_dir), do: require_data_path!(upload_dir, "UPLOAD_DIR")
    if is_binary(attachment_dir), do: require_data_path!(attachment_dir, "ATTACHMENT_DIR")

    on_volume =
      [
        local_database? && "its SQLite database",
        is_binary(upload_dir) && "uploads",
        is_binary(attachment_dir) && "inbound attachments"
      ]
      |> Enum.filter(& &1)

    if on_volume != [] do
      require_data_mount!(opts)
      require_single_machine!(on_volume, opts)
    end
  end

  # A remote database is not local even if a :database path is left over.
  defp local_database?(repo_config) do
    is_binary(Keyword.get(repo_config, :database)) and
      not Keyword.has_key?(repo_config, :url) and not Adapter.turso?(repo_config)
  end

  # Moving to Turso leaves the SQLite file on the volume, and nothing reads
  # it again. Say so on every boot until it is gone, so a switch nobody meant
  # (a stale DATABASE_URL synced from .env.secrets) does not go unnoticed.
  defp warn_about_left_behind_sqlite(opts) do
    path =
      Keyword.get_lazy(opts, :sqlite_path, fn ->
        System.get_env("DATABASE_PATH") || Path.join(@data_dir, "custyard.db")
      end)

    if File.exists?(path) do
      Log.warning(:unused_local_database_detected)
    end
  end

  # A Fly volume attaches to exactly one machine, so a second machine gets a
  # second volume holding a second copy of everything under /data. Nothing
  # reports an error while the copies diverge: each machine passes its own
  # health check, and a write lands on whichever machine the proxy happened to
  # route to. A remote database does not change this, because uploads and
  # attachments stay on the volume.
  defp require_single_machine!(on_volume, opts) do
    case Keyword.get_lazy(opts, :machine_ids, &deployed_machine_ids/0) do
      {:ok, [_, _ | _] = ids} ->
        raise_multiple_machines!(ids, on_volume)

      {:ok, _one} ->
        :ok

      :unknown ->
        Log.warning(:fly_machine_count_unknown)
    end
  end

  defp deployed_machine_ids do
    app = System.get_env("FLY_APP_NAME")
    name = ~c"all.vms.#{app}.internal"

    case :inet_res.lookup(name, :in, :txt, [], @machine_dns_timeout) do
      [] ->
        :unknown

      records ->
        case parse_machine_ids(records) do
          [] -> :unknown
          ids -> {:ok, ids}
        end
    end
  end

  # `all.vms.<app>.internal` answers with TXT records holding a comma-separated
  # list of machine id and region, covering stopped machines as well as started
  # ones. Regions are three letters, so hex tokens of eight characters or more
  # are the machine ids.
  defp parse_machine_ids(records) do
    records
    |> Enum.map(&record_to_string/1)
    |> Enum.flat_map(&String.split(&1, ",", trim: true))
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&machine_id?/1)
    |> Enum.uniq()
  end

  # A TXT record arrives as a list of chunks, and a long value is split across
  # them. Accept a bare charlist too, rather than decoding one as numbers.
  defp record_to_string(parts) when is_list(parts) do
    Enum.map_join(parts, fn
      part when is_list(part) -> to_string(part)
      part when is_integer(part) -> <<part::utf8>>
      part when is_binary(part) -> part
    end)
  end

  defp machine_id?(token) do
    String.length(token) >= 8 and String.match?(token, ~r/^[0-9a-f]+$/)
  end

  defp raise_multiple_machines!(ids, on_volume) do
    raise """
    This Fly app has #{length(ids)} machines and keeps
    #{join_with_and(on_volume)} under #{@data_dir}. A Fly volume attaches to one
    machine, so every machine has its own volume and its own copy of that data,
    and the copies diverge from the moment they are created.

    Run a single machine:

        fly scale count 1 -a YOUR_APP_NAME

    `min_machines_running` does not prevent this. It is a floor on how many
    machines stay warm, not a cap on how many exist.

    A Turso or PostgreSQL database does not lift the limit while uploads and
    attachments are files under #{@data_dir}, because each volume holds its own
    copy.
    """
  end

  defp join_with_and([item]), do: item

  defp join_with_and(items) do
    {init, [last]} = Enum.split(items, -1)
    Enum.join(init, ", ") <> " and " <> last
  end

  defp require_data_mount!(opts) do
    mountinfo =
      case Keyword.fetch(opts, :mountinfo) do
        {:ok, {:error, _reason} = error} -> error
        {:ok, contents} -> {:ok, contents}
        :error -> File.read("/proc/self/mountinfo")
      end

    case mountinfo do
      {:ok, contents} ->
        if not mounted_data_volume?(contents), do: raise_missing_volume!()

      {:error, reason} ->
        Log.error(:fly_mount_verification_failed, Log.failure(reason))
        raise "Cannot verify Fly volume mount at /data; check the filesystem error event"
    end
  end

  defp require_data_path!(path, env_var) do
    expanded = Path.expand(path)

    unless String.starts_with?(expanded, @data_dir <> "/") do
      raise "#{env_var} must point inside the mounted /data volume on Fly.io"
    end
  end

  defp mounted_data_volume?(mountinfo) do
    mountinfo
    |> String.split("\n", trim: true)
    |> Enum.any?(fn line ->
      line
      |> String.split(" ", parts: 6)
      |> Enum.at(4) == @data_dir
    end)
  end

  defp raise_missing_volume! do
    raise """
    Fly.io has no mounted volume at /data. Refusing to start because SQLite or
    uploads would be written to the ephemeral container filesystem. Create a
    custyard_data volume and enable the /data mount in fly.toml.
    """
  end
end
