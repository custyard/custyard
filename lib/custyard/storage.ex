defmodule Custyard.Storage do
  @moduledoc """
  Verifies that Fly's local database, uploads and attachments live on a mounted
  volume attached to the app's only machine.

  A remote database (Turso over `libsql://`, or PostgreSQL) is not on the
  volume, so its path is not checked. Uploads and attachments still are, so
  the app still runs on one machine.

  `check/1` runs before the Repo starts (`Custyard.Boot.Probe` at boot, the
  release CLI before opening the database), so a missing volume cannot
  silently create a fresh database on the container filesystem, and a second
  machine cannot silently create a second copy of what the volume stores. It
  returns the problem; `validate_fly_storage!/1` raises it for the release
  tasks that still stop on it.
  """

  alias Custyard.Repo.Adapter

  require Custyard.Log, as: Log

  @data_dir "/data"
  @mountinfo "/proc/self/mountinfo"

  # Internal Fly DNS, so a lookup should answer in well under a second. Boot
  # continues when it does not: an unreachable resolver is not evidence of a
  # second machine.
  @machine_dns_timeout 2_000

  @type problem :: :volume_missing | :multiple_machines

  @doc """
  `:ok`, or `{:error, problem, detail}` where `detail` names no configured
  path or machine id. Off Fly (no `FLY_APP_NAME`) nothing is checked.

  Options, mostly for tests: `:fly_app_name`, `:repo_config`, `:upload_dir`,
  `:attachment_dir`, `:mountinfo` (contents or `{:error, reason}`),
  `:machine_ids` (`{:ok, ids}` or `:unknown`), `:sqlite_path`.
  """
  @spec check(keyword) :: :ok | {:error, problem, String.t()}
  def check(opts \\ []) do
    if Keyword.get(opts, :fly_app_name, System.get_env("FLY_APP_NAME")) do
      repo_config =
        Keyword.get(opts, :repo_config, Application.get_env(:custyard, Custyard.Repo, []))

      with :ok <- check_fly_paths(repo_config, opts) do
        if Adapter.turso?(repo_config), do: warn_about_left_behind_sqlite(opts)
        :ok
      end
    else
      :ok
    end
  end

  @doc "`check/1`, raising a `RuntimeError` with the detail on a problem."
  @spec validate_fly_storage!(keyword) :: :ok
  def validate_fly_storage!(opts \\ []) do
    case check(opts) do
      :ok -> :ok
      {:error, _problem, detail} -> raise detail
    end
  end

  @doc """
  Whether `path` is on a mounted filesystem other than the root one,
  according to `/proc/self/mountinfo`. `nil` where that file does not exist
  (macOS, some sandboxes), so callers can say "unknown" instead of "no".
  """
  @spec mounted?(Path.t(), {:ok, String.t()} | {:error, term} | nil) :: boolean | nil
  def mounted?(path, mountinfo \\ nil) do
    case mountinfo || File.read(@mountinfo) do
      {:ok, contents} -> mount_point_of(contents, Path.expand(path)) not in [nil, "/"]
      {:error, _reason} -> nil
    end
  end

  defp check_fly_paths(repo_config, opts) do
    upload_dir = Keyword.get(opts, :upload_dir, Application.get_env(:custyard, :upload_dir))

    attachment_dir =
      Keyword.get(opts, :attachment_dir, Application.get_env(:custyard, :attachment_dir))

    database_path = Keyword.get(repo_config, :database)
    local_database? = local_database?(repo_config)

    on_volume =
      [
        local_database? && "its SQLite database",
        is_binary(upload_dir) && "uploads",
        is_binary(attachment_dir) && "inbound attachments"
      ]
      |> Enum.filter(& &1)

    with :ok <- data_path(local_database? && database_path, "DATABASE_PATH"),
         :ok <- data_path(upload_dir, "UPLOAD_DIR"),
         :ok <- data_path(attachment_dir, "ATTACHMENT_DIR") do
      if on_volume == [] do
        :ok
      else
        with :ok <- data_mount(opts), do: single_machine(on_volume, opts)
      end
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
  defp single_machine(on_volume, opts) do
    case Keyword.get_lazy(opts, :machine_ids, &deployed_machine_ids/0) do
      {:ok, [_, _ | _] = ids} ->
        {:error, :multiple_machines, multiple_machines_detail(ids, on_volume)}

      {:ok, _one} ->
        :ok

      :unknown ->
        Log.warning(:fly_machine_count_unknown)
        :ok
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

  defp multiple_machines_detail(ids, on_volume) do
    """
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

  defp data_mount(opts) do
    mountinfo =
      case Keyword.fetch(opts, :mountinfo) do
        {:ok, {:error, _reason} = error} -> error
        {:ok, contents} -> {:ok, contents}
        :error -> File.read(@mountinfo)
      end

    case mountinfo do
      {:ok, contents} ->
        if mount_point?(contents, @data_dir),
          do: :ok,
          else: {:error, :volume_missing, missing_volume_detail()}

      {:error, reason} ->
        Log.error(:fly_mount_verification_failed, Log.failure(reason))

        {:error, :volume_missing,
         "Cannot verify Fly volume mount at /data; check the filesystem error event"}
    end
  end

  defp data_path(path, _env_var) when not is_binary(path), do: :ok

  defp data_path(path, env_var) do
    expanded = Path.expand(path)

    if String.starts_with?(expanded, @data_dir <> "/"),
      do: :ok,
      else:
        {:error, :volume_missing,
         "#{env_var} must point inside the mounted #{@data_dir} volume on Fly.io"}
  end

  defp mount_point?(mountinfo, dir), do: dir in mount_points(mountinfo)

  # The deepest mount point that contains `path`, or nil.
  defp mount_point_of(mountinfo, path) do
    mountinfo
    |> mount_points()
    |> Enum.filter(&(&1 == "/" or path == &1 or String.starts_with?(path, &1 <> "/")))
    |> Enum.max_by(&String.length/1, fn -> nil end)
  end

  # Field 5 of each mountinfo line is the mount point.
  defp mount_points(mountinfo) do
    mountinfo
    |> String.split("\n", trim: true)
    |> Enum.map(&(&1 |> String.split(" ", parts: 6) |> Enum.at(4)))
    |> Enum.reject(&is_nil/1)
  end

  defp missing_volume_detail do
    """
    Fly.io has no mounted volume at /data. Refusing to start because SQLite or
    uploads would be written to the ephemeral container filesystem. Create a
    custyard_data volume and enable the /data mount in fly.toml.
    """
  end
end
