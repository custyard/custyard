defmodule Custyard.Release do
  @moduledoc """
  Release tasks run with `bin/custyard eval`: migrations, the operator
  bootstrap the container entrypoint runs before the server, the
  `bin/operator` and `bin/dsar` command lines (`rel/overlays/bin/operator`,
  `rel/overlays/bin/dsar`; the latter's commands are `Custyard.Release.Dsar`),
  and the SQLite export for moving the database to Turso.

  None of these start the application. They load its configuration and start
  only the Repo (`Ecto.Migrator.with_repo/2`), so they are safe to run on a
  machine whose server is already up, and they never start the endpoint,
  mail pollers or background workers.
  """

  alias Custyard.{InstanceAdmins, Repo}
  alias Custyard.Repo.Adapter
  alias Custyard.Release.Dsar

  require Logger

  @app :custyard

  @operator_usage """
  Usage: bin/instance-admin add EMAIL | list | remove EMAIL | help
  Instance administrators sign in at /admin/login and provision tenant staff
  through the instance console. Staff sign in separately on their tenant host.
  """

  def migrate do
    load_app()
    Custyard.Storage.validate_fly_storage!()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    Custyard.Storage.validate_fly_storage!()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Copies the local SQLite database into one file for
  `turso db create --from-file`, next to the database unless `path` says
  otherwise, and returns its path.

  The copy is a consistent snapshot (`VACUUM INTO`); writes after it are not
  in it, so stop the app first (`MAINTENANCE_MODE`, docs/ops/database.md).
  Run it as `custyard`: even read-only, SQLite creates the database's `-wal`
  and `-shm` files when they are missing, and root-owned ones would leave
  the app unable to write the file if you go back to it.

      fly ssh console -C "runuser -u custyard -- /app/bin/custyard eval 'Custyard.Release.export_sqlite()'"
  """
  def export_sqlite(path \\ nil) do
    load_app()
    {:ok, _} = Application.ensure_all_started(:exqlite)

    config = Application.get_env(@app, Repo, [])

    if Adapter.turso?(config) or !config[:database],
      do:
        raise("the database is not a local SQLite file (DATABASE_URL is set); nothing to export")

    source = config[:database]

    path = path || Path.join(Path.dirname(source), "turso-import.db")
    if File.exists?(path), do: raise("#{path} already exists; move it aside first")

    {:ok, db} = Exqlite.Sqlite3.open(source, mode: :readonly)

    try do
      {:ok, statement} = Exqlite.Sqlite3.prepare(db, "VACUUM INTO ?1")
      :ok = Exqlite.Sqlite3.bind(statement, [path])
      :done = Exqlite.Sqlite3.step(db, statement)
    after
      Exqlite.Sqlite3.close(db)
    end

    # Turso's import takes a database in WAL mode; the mode is stored in the
    # file.
    {:ok, copy} = Exqlite.Sqlite3.open(path)
    :ok = Exqlite.Sqlite3.execute(copy, "PRAGMA journal_mode = WAL")
    :ok = Exqlite.Sqlite3.close(copy)

    IO.puts("Exported #{source} to #{path}")
    path
  end

  @doc "Creates an installation administrator without starting the application."
  def setup_instance_admin(email), do: with_repo(fn -> InstanceAdmins.create_admin(email) end)

  def bootstrap_instance_admin do
    case System.get_env("INSTANCE_ADMIN_EMAIL") do
      value when is_binary(value) ->
        if String.trim(value) != "" do
          case setup_instance_admin(value) do
            {:created, _} ->
              :ok

            {:exists, _} ->
              :ok

            {:error, reason} ->
              raise "Could not create instance administrator: #{inspect(reason)}"
          end
        end

      _ ->
        :ok
    end
  end

  def instance_admin_cli(argv), do: argv |> run_instance_admin_cli() |> System.halt()

  def run_instance_admin_cli(["help"]) do
    IO.write(@operator_usage)
    0
  end

  def run_instance_admin_cli(argv) do
    case with_repo(fn -> admin_command(argv) end) do
      {:ok, lines} ->
        Enum.each(lines, &IO.puts/1)
        0

      {:error, reason} ->
        IO.puts(:stderr, "Error: #{inspect(reason)}")
        1
    end
  end

  defp admin_command(["add", email]) do
    case InstanceAdmins.create_admin(email) do
      {status, admin} when status in [:created, :exists] ->
        {:ok, ["#{status} instance admin #{admin.id}: #{admin.email}. Sign in at /admin/login."]}

      error ->
        error
    end
  end

  defp admin_command(["list"]),
    do: {:ok, Enum.map(InstanceAdmins.list_admins(), &"#{&1.id} #{&1.email}")}

  defp admin_command(["remove", email]) do
    case InstanceAdmins.remove_admin(email) do
      {:ok, admin} -> {:ok, ["Removed instance admin #{admin.email}"]}
      error -> error
    end
  end

  defp admin_command(_), do: {:error, @operator_usage}
  def dsar_cli(argv), do: argv |> Dsar.run() |> System.halt()

  @doc false
  # Loads config and starts only the Repo for `fun`. Never starts the app.
  # The storage check runs before the Repo starts, as migrate/0 does: opening
  # SQLite first would create an empty database on the container's root
  # filesystem when the Fly volume is missing. Shared with Custyard.Release.Dsar.
  def with_repo(fun) when is_function(fun, 0) do
    load_app()
    Custyard.Storage.validate_fly_storage!()

    case Ecto.Migrator.with_repo(Repo, fn _repo -> fun.() end) do
      {:ok, result, _started} -> result
      {:error, reason} -> {:error, "could not start the database: #{inspect(reason)}"}
    end
  end

  defp load_app do
    Application.load(@app)
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end
end
