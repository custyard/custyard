defmodule Custyard.Storage do
  @moduledoc """
  Verifies that Fly's local database and uploads live on a mounted volume.

  The check runs before the Repo and release migrations start, so a missing
  volume cannot silently create a fresh database on the container filesystem.
  """

  @data_dir "/data"

  def validate_fly_storage!(opts \\ []) do
    if Keyword.get(opts, :fly_app_name, System.get_env("FLY_APP_NAME")),
      do: validate_fly_paths!(opts)

    :ok
  end

  defp validate_fly_paths!(opts) do
    repo_config =
      Keyword.get(opts, :repo_config, Application.get_env(:custyard, Custyard.Repo, []))

    upload_dir = Keyword.get(opts, :upload_dir, Application.get_env(:custyard, :upload_dir))
    database_path = Keyword.get(repo_config, :database)
    local_database? = is_binary(database_path) and not Keyword.has_key?(repo_config, :url)

    if local_database?, do: require_data_path!(database_path, "DATABASE_PATH")
    if is_binary(upload_dir), do: require_data_path!(upload_dir, "UPLOAD_DIR")
    if local_database? or is_binary(upload_dir), do: require_data_mount!(opts)
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
