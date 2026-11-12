defmodule Custyard.Storage do
  @moduledoc """
  Verifies where the database lives before release tasks or the Repo start.

  Uploaded files and inbound attachments are stored in the application
  database, so the database is the only thing a deployment has to keep. A
  remote database (Turso or Bunny Database over libSQL, or PostgreSQL) needs
  no volume and lifts the single-machine limit. A local SQLite database does
  neither: on Fly it must live on a mounted volume attached to the app's only
  machine.

  Bunny hosting has no local database to fall back to: it requires the
  configured Bunny Database.

  `check/1` runs before the Repo starts (`Custyard.Boot.Probe` at boot, the
  release CLI before opening the database), so a missing volume cannot
  silently create a fresh SQLite database on the container filesystem, and a
  second machine cannot silently create a second copy of it. It returns the
  problem; `validate!/1` raises it for the release tasks that still stop on
  it.

  The provider comes from `STORAGE_PROVIDER` (`config :custyard,
  :storage_provider`, parsed by `Custyard.Boot.Env`): `:local` checks nothing,
  `:fly` checks the volume under a local SQLite database, `:bunny` checks that
  the database is the Bunny one. Unset, Fly is detected from `FLY_APP_NAME`.
  """

  alias Custyard.Repo.Adapter

  require Custyard.Log, as: Log

  @data_dir "/data"
  @mountinfo "/proc/self/mountinfo"

  # Internal Fly DNS, so a lookup should answer in well under a second. Boot
  # continues when it does not: an unreachable resolver is not evidence of a
  # second machine.
  @machine_dns_timeout 2_000

  @type problem ::
          :volume_missing | :multiple_machines | :bunny_database_required | :provider_unsupported

  @doc """
  `:ok`, or `{:error, problem, detail}` where `detail` names no configured
  path or machine id. With the `:local` provider nothing is checked.

  Options, mostly for tests: `:provider` (`:local | :fly | :bunny`),
  `:fly_app_name` (truthy selects Fly, `nil` selects local, when `:provider`
  is absent), `:repo_config`, `:mountinfo` (contents or `{:error, reason}`),
  `:machine_ids` (`{:ok, ids}` or `:unknown`) and `:sqlite_path`.
  """
  @spec check(keyword) :: :ok | {:error, problem, String.t()}
  def check(opts \\ []) do
    case provider(opts) do
      :local -> :ok
      :fly -> check_fly(opts)
      :bunny -> check_bunny(opts)
      _ -> {:error, :provider_unsupported, "STORAGE_PROVIDER must be local, fly or bunny"}
    end
  end

  @doc "`check/1`, raising a `RuntimeError` with the detail on a problem."
  @spec validate!(keyword) :: :ok
  def validate!(opts \\ []), do: opts |> check() |> raise_on_problem()

  @doc """
  The Fly check alone, raising on a problem. Off Fly (no `FLY_APP_NAME`, or
  `fly_app_name: nil`) nothing is checked, whatever the configured provider.
  """
  @spec validate_fly_storage!(keyword) :: :ok
  def validate_fly_storage!(opts \\ []) do
    if Keyword.get(opts, :fly_app_name, System.get_env("FLY_APP_NAME")),
      do: opts |> check_fly() |> raise_on_problem(),
      else: :ok
  end

  defp raise_on_problem(:ok), do: :ok
  defp raise_on_problem({:error, _problem, detail}), do: raise(detail)

  # An explicit :fly_app_name (tests, validate_fly_storage!/1) decides between
  # Fly and local on its own; otherwise the configured provider, and without
  # one (dev, test, a release whose STORAGE_PROVIDER is unset) Fly detection.
  defp provider(opts) do
    cond do
      Keyword.has_key?(opts, :provider) ->
        opts[:provider]

      Keyword.has_key?(opts, :fly_app_name) ->
        if opts[:fly_app_name], do: :fly, else: :local

      true ->
        Application.get_env(:custyard, :storage_provider) ||
          if(System.get_env("FLY_APP_NAME"), do: :fly, else: :local)
    end
  end

  # Only a local SQLite database is on the volume. A remote one is checked for
  # nothing here: no mount, and any number of machines.
  defp check_fly(opts) do
    repo_config = repo_config(opts)

    if local_database?(repo_config) do
      with :ok <- database_path(Keyword.get(repo_config, :database)),
           :ok <- data_mount(opts) do
        single_machine(opts)
      end
    else
      if Adapter.turso?(repo_config), do: warn_about_left_behind_sqlite(opts)
      :ok
    end
  end

  # Bunny hosting mounts no volume, so a SQLite file there would be lost with
  # the container. Only the configured Bunny Database is accepted.
  defp check_bunny(opts) do
    repo_config = repo_config(opts)

    if repo_config[:turso_provider] == :bunny and Adapter.turso?(repo_config) do
      :ok
    else
      {:error, :bunny_database_required,
       "Bunny storage requires the configured Bunny remote database; refusing local fallback"}
    end
  end

  defp repo_config(opts) do
    Keyword.get(opts, :repo_config, Application.get_env(:custyard, Custyard.Repo, []))
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
  # second volume holding a second SQLite database. Nothing reports an error
  # while the copies diverge: each machine passes its own health check, and a
  # write lands on whichever machine the proxy happened to route to. Only
  # called for a local database: every machine shares a remote one, files
  # included.
  defp single_machine(opts) do
    case Keyword.get_lazy(opts, :machine_ids, &deployed_machine_ids/0) do
      {:ok, [_, _ | _] = ids} ->
        {:error, :multiple_machines, multiple_machines_detail(ids)}

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

  defp multiple_machines_detail(ids) do
    """
    This Fly app has #{length(ids)} machines and keeps its SQLite database
    under #{@data_dir}. A Fly volume attaches to one machine, so every machine
    has its own volume and its own copy of the database, and the copies diverge
    from the moment they are created.

    Run a single machine:

        fly scale count 1 -a YOUR_APP_NAME

    `min_machines_running` does not prevent this. It is a floor on how many
    machines stay warm, not a cap on how many exist.

    A remote database (Turso, Bunny Database or PostgreSQL) lifts the limit:
    uploaded files and attachments are stored in the database, so every machine
    then shares all of it.
    """
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

  defp database_path(path) do
    if String.starts_with?(Path.expand(path), @data_dir <> "/"),
      do: :ok,
      else:
        {:error, :volume_missing,
         "DATABASE_PATH must point inside the mounted #{@data_dir} volume on Fly.io"}
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
    Fly.io has no mounted volume at /data. Refusing to start because the SQLite
    database would be written to the ephemeral container filesystem. Create a
    custyard_data volume and enable the /data mount in fly.toml, or configure a
    remote database, which needs no volume.
    """
  end
end
