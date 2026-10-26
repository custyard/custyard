defmodule Custyard.Storage do
  @moduledoc """
  Verifies that Fly's local database and uploads live on a mounted volume
  attached to the app's only machine.

  The check runs before the Repo and release migrations start, so a missing
  volume cannot silently create a fresh database on the container filesystem,
  and a second machine cannot silently create a second database.
  """

  require Logger

  @data_dir "/data"

  # Internal Fly DNS, so a lookup should answer in well under a second. Boot
  # continues when it does not: an unreachable resolver is not evidence of a
  # second machine.
  @machine_dns_timeout 2_000

  def validate_fly_storage!(opts \\ []) do
    if Keyword.get(opts, :fly_app_name, System.get_env("FLY_APP_NAME")),
      do: validate_fly_paths!(opts)

    :ok
  end

  defp validate_fly_paths!(opts) do
    repo_config =
      Keyword.get(opts, :repo_config, Application.get_env(:custyard, Custyard.Repo, []))

    upload_dir = Keyword.get(opts, :upload_dir, Application.get_env(:custyard, :upload_dir))

    attachment_dir =
      Keyword.get(opts, :attachment_dir, Application.get_env(:custyard, :attachment_dir))

    database_path = Keyword.get(repo_config, :database)
    local_database? = is_binary(database_path) and not Keyword.has_key?(repo_config, :url)

    if local_database?, do: require_data_path!(database_path, "DATABASE_PATH")
    if is_binary(upload_dir), do: require_data_path!(upload_dir, "UPLOAD_DIR")
    if is_binary(attachment_dir), do: require_data_path!(attachment_dir, "ATTACHMENT_DIR")

    if local_database? or is_binary(upload_dir) or is_binary(attachment_dir),
      do: require_data_mount!(opts)

    if local_database?, do: require_single_machine!(opts)
  end

  # A Fly volume attaches to exactly one machine, so a second machine gets a
  # second volume holding a second SQLite database. Nothing reports an error
  # while the two diverge: each machine passes its own health check, and a
  # write lands on whichever machine the proxy happened to route to.
  defp require_single_machine!(opts) do
    case Keyword.get_lazy(opts, :machine_ids, &deployed_machine_ids/0) do
      {:ok, [_, _ | _] = ids} ->
        raise_multiple_machines!(ids)

      {:ok, _one} ->
        :ok

      :unknown ->
        Logger.warning(
          "Cannot determine how many machines this Fly app has, so the " <>
            "single-machine requirement for local SQLite is unverified. " <>
            "Confirm with `fly scale show`."
        )
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

  defp raise_multiple_machines!(ids) do
    raise """
    This Fly app has #{length(ids)} machines (#{Enum.join(ids, ", ")}) and keeps
    its database in a local SQLite file under #{@data_dir}. A Fly volume attaches
    to one machine, so every machine has its own volume and its own database,
    and they diverge from the moment they are created.

    Run a single machine:

        fly scale count 1 -a #{System.get_env("FLY_APP_NAME")}

    `min_machines_running` does not prevent this. It is a floor on how many
    machines stay warm, not a cap on how many exist. For more than one machine,
    build the release with Ecto.Adapters.Postgres and set DATABASE_URL.
    """
  end

  defp require_data_mount!(opts) do
    mountinfo =
      case Keyword.fetch(opts, :mountinfo) do
        {:ok, contents} -> {:ok, contents}
        :error -> File.read("/proc/self/mountinfo")
      end

    case mountinfo do
      {:ok, contents} ->
        if not mounted_data_volume?(contents), do: raise_missing_volume!()

      {:error, reason} ->
        raise "Cannot verify Fly volume mount at /data: #{inspect(reason)}"
    end
  end

  defp require_data_path!(path, env_var) do
    expanded = Path.expand(path)

    unless String.starts_with?(expanded, @data_dir <> "/") do
      raise "#{env_var} must point inside the mounted /data volume on Fly.io (got #{inspect(path)})"
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
