defmodule Custyard.Repo.Adapter do
  @moduledoc """
  `Ecto.Adapters.SQLite3`, reaching the database either as a local file or
  as a Turso (libSQL) database over HTTP.

  Turso is SQLite on the server, so the SQL, the column types and the way
  values are stored do not change. Only the connection does: with
  `:turso_url` in the Repo config, connections are `Custyard.Turso.Connection`;
  with `:database`, they are Exqlite's, exactly as under
  `Ecto.Adapters.SQLite3`. Everything else delegates to that adapter, so a
  database moves between the two without converting a row.

  The connection module delegates to `Ecto.Adapters.SQLite3.Connection`,
  which ecto_sqlite3 marks internal. It implements the public
  `Ecto.Adapters.SQL.Connection` behaviour, and the test suite runs against
  it either way.
  """

  use Ecto.Adapters.SQL, driver: :exqlite

  @behaviour Ecto.Adapter.Storage
  @behaviour Ecto.Adapter.Structure

  @sqlite Ecto.Adapters.SQLite3

  @doc false
  def turso?(opts), do: Keyword.has_key?(opts, :turso_url)

  @impl Ecto.Adapter
  def ensure_all_started(config, type) do
    with {:ok, started} <- super(config, type),
         {:ok, http} <- Application.ensure_all_started(:mint, type) do
      {:ok, started ++ http}
    end
  end

  @impl Ecto.Adapter
  defdelegate loaders(primitive, type), to: @sqlite

  @impl Ecto.Adapter
  defdelegate dumpers(primitive, type), to: @sqlite

  @impl Ecto.Adapter.Schema
  defdelegate autogenerate(type), to: @sqlite

  @impl Ecto.Adapter.Migration
  defdelegate supports_ddl_transaction?, to: @sqlite

  @impl Ecto.Adapter.Migration
  defdelegate lock_for_migrations(meta, opts, fun), to: @sqlite

  # A Turso database is created and dropped with the turso CLI, never by
  # `mix ecto.create` or `mix ecto.drop`.

  @impl Ecto.Adapter.Storage
  def storage_up(opts) do
    if turso?(opts), do: {:error, :already_up}, else: @sqlite.storage_up(opts)
  end

  @impl Ecto.Adapter.Storage
  def storage_down(opts) do
    if turso?(opts),
      do: {:error, "a Turso database is dropped with `turso db destroy`, not by Ecto"},
      else: @sqlite.storage_down(opts)
  end

  @impl Ecto.Adapter.Storage
  def storage_status(opts) do
    if turso?(opts), do: :up, else: @sqlite.storage_status(opts)
  end

  @impl Ecto.Adapter.Structure
  def structure_dump(default, config) do
    if turso?(config), do: turso_structure_error(), else: @sqlite.structure_dump(default, config)
  end

  @impl Ecto.Adapter.Structure
  def structure_load(default, config) do
    if turso?(config), do: turso_structure_error(), else: @sqlite.structure_load(default, config)
  end

  @impl Ecto.Adapter.Structure
  def dump_cmd(args, opts \\ [], config) do
    if turso?(config),
      do: {"dump_cmd needs a local SQLite file; use `turso db shell` for Turso", 1},
      else: @sqlite.dump_cmd(args, opts, config)
  end

  defp turso_structure_error,
    do: {:error, "structure dump and load need a local SQLite file; use `turso db shell`"}
end

defmodule Custyard.Repo.Adapter.Connection do
  @moduledoc false

  @behaviour Ecto.Adapters.SQL.Connection

  alias Custyard.Repo.Adapter

  @sqlite Ecto.Adapters.SQLite3.Connection

  @impl true
  def child_spec(opts) do
    if Adapter.turso?(opts) do
      {:ok, _} = Application.ensure_all_started(:db_connection)
      DBConnection.child_spec(Custyard.Turso.Connection, opts)
    else
      @sqlite.child_spec(opts)
    end
  end

  @impl true
  defdelegate prepare_execute(conn, name, sql, params, opts), to: @sqlite

  @impl true
  defdelegate execute(conn, query, params, opts), to: @sqlite

  @impl true
  defdelegate query(conn, sql, params, opts), to: @sqlite

  @impl true
  defdelegate query_many(conn, sql, params, opts), to: @sqlite

  @impl true
  defdelegate stream(conn, sql, params, opts), to: @sqlite

  @impl true
  defdelegate to_constraints(error, opts), to: @sqlite

  @impl true
  defdelegate all(query), to: @sqlite

  @impl true
  defdelegate update_all(query), to: @sqlite

  @impl true
  defdelegate delete_all(query), to: @sqlite

  # Ecto.Adapters.SQL calls insert/7 for a single row, insert/8 for insert_all.
  @impl true
  defdelegate insert(
                prefix,
                table,
                header,
                rows,
                on_conflict,
                returning,
                placeholders,
                opts \\ []
              ),
              to: @sqlite

  @impl true
  defdelegate update(prefix, table, fields, filters, returning), to: @sqlite

  @impl true
  defdelegate delete(prefix, table, filters, returning), to: @sqlite

  @impl true
  defdelegate explain_query(conn, query, params, opts), to: @sqlite

  @impl true
  defdelegate execute_ddl(command), to: @sqlite

  @impl true
  defdelegate ddl_logs(result), to: @sqlite

  @impl true
  defdelegate table_exists_query(table), to: @sqlite
end
