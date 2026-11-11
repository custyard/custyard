# Used by bunny-database-check, before Ecto creates or migrates any tables.
{:ok, _} = Application.ensure_all_started([:exqlite, :db_connection, :mint, :jason])

alias Custyard.Turso.Connection

opts = [
  turso_url: System.fetch_env!("TURSO_TEST_URL"),
  turso_auth_token: System.fetch_env!("TURSO_TEST_AUTH_TOKEN"),
  turso_provider: :bunny
]

case Connection.connect(opts) do
  {:ok, state} ->
    query =
      Exqlite.Query.build(
        statement:
          "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'"
      )

    case Connection.handle_execute(query, [], [], state) do
      {:ok, _, %Exqlite.Result{rows: []}, state} ->
        Connection.disconnect(nil, state)
        IO.puts("Empty disposable database verified; running migrations and tests.")

      {_, _, state} ->
        Connection.disconnect(nil, state)
        raise "Database preflight failed; refusing to run migrations or tests"

      {:ok, _, _, state} ->
        Connection.disconnect(nil, state)
        raise "Database is not empty; refusing to run migrations or tests"
    end

  {:error, _} ->
    raise "Bunny database preflight failed; verify URL, token and interactive-session support"
end
