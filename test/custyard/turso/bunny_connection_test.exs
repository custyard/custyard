defmodule Custyard.Turso.BunnyConnectionTest do
  use ExUnit.Case, async: true

  alias Custyard.Turso.{Connection, Protocol}
  alias Custyard.TursoTestServer

  @moduletag :tmp_dir

  defmodule Repo do
    use Ecto.Repo, otp_app: :custyard, adapter: Custyard.Repo.Adapter
  end

  setup context do
    server =
      start_supervised!(
        {TursoTestServer,
         [database: Path.join(context.tmp_dir, "bunny.db"), protocol: :v2] ++
           (context[:server] || [])}
      )

    url = TursoTestServer.url(server)
    %{url: url}
  end

  defp repo(url) do
    pid =
      start_supervised!(
        {Repo, name: nil, turso_url: url, turso_provider: :bunny, pool_size: 2, log: false}
      )

    Repo.put_dynamic_repo(pid)

    Repo.query!(
      "CREATE TABLE items (id INTEGER PRIMARY KEY, name TEXT UNIQUE, data BLOB, count INTEGER)"
    )

    pid
  end

  test "v2 selects the correct endpoint including a supplied pipeline URL", %{url: url} do
    assert {:ok, endpoint} = Protocol.parse_url("https://test.lite.bunnydb.net/v2/pipeline", :v2)
    assert Protocol.pipeline_path(endpoint, :v2) == "/v2/pipeline"
    assert {:error, _} = Protocol.parse_url("https://test.invalid/v3/pipeline", :v2)
    assert {:ok, state} = Connection.connect(turso_url: url, turso_provider: :bunny)
    assert state.protocol == :v2
    assert state.transaction_status == :idle
    Connection.disconnect(nil, state)
  end

  test "v2 values and constraints survive conditional primary batches", %{url: url} do
    repo(url)

    Repo.query!("INSERT INTO items (name, data, count) VALUES (?, ?, ?)", [
      "one",
      {:blob, <<0, 255>>},
      9_223_372_036_854_775_807
    ])

    assert %{rows: [["one", <<0, 255>>, 9_223_372_036_854_775_807]]} =
             Repo.query!("SELECT name, data, count FROM items")

    assert {:error, %Exqlite.Error{message: "UNIQUE constraint failed: items.name"}} =
             Repo.query("INSERT INTO items (name) VALUES ('one')")

    assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM items")
  end

  test "batons preserve transactions, rollback and savepoints on v2", %{url: url} do
    repo(url)

    assert {:error, :undo} =
             Repo.transaction(fn ->
               Repo.query!("INSERT INTO items (name) VALUES ('rolled back')")
               Repo.rollback(:undo)
             end)

    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM items")

    {:ok, state} = Connection.connect(turso_url: url, turso_provider: :bunny)
    {:ok, _, state} = Connection.handle_begin([], state)
    query = Exqlite.Query.build(statement: "INSERT INTO items (name) VALUES (?)")
    {:ok, _, _, state} = Connection.handle_execute(query, ["outer"], [], state)
    {:ok, _, state} = Connection.handle_begin([mode: :savepoint], state)
    {:ok, _, _, state} = Connection.handle_execute(query, ["inner"], [], state)
    {:ok, _, state} = Connection.handle_rollback([mode: :savepoint], state)
    {:ok, _, state} = Connection.handle_commit([], state)
    Connection.disconnect(nil, state)
    assert %{rows: [["outer"]]} = Repo.query!("SELECT name FROM items")
  end

  test "ordinary errors retain the transaction; automatic rollback disconnects", %{url: url} do
    repo(url)
    {:ok, state} = Connection.connect(turso_url: url, turso_provider: :bunny)
    {:ok, _, state} = Connection.handle_begin([], state)
    insert = Exqlite.Query.build(statement: "INSERT INTO items (name) VALUES ('one')")
    {:ok, _, _, state} = Connection.handle_execute(insert, [], [], state)
    assert {:error, %Exqlite.Error{}, state} = Connection.handle_execute(insert, [], [], state)

    rollback =
      Exqlite.Query.build(statement: "INSERT OR ROLLBACK INTO items (name) VALUES ('one')")

    assert {:disconnect, %DBConnection.ConnectionError{}, state} =
             Connection.handle_execute(rollback, [], [], state)

    Connection.disconnect(nil, state)
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM items")
    # The abandoned stream must release its write lock without waiting for expiry.
    Repo.query!("INSERT INTO items (name) VALUES ('after')")
  end

  test "raw transaction control cannot silently end a v2 transaction", %{url: url} do
    {:ok, state} = Connection.connect(turso_url: url, turso_provider: :bunny)
    {:ok, _, state} = Connection.handle_begin([], state)

    for sql <- [
          "/* prefix */ -- comment\nCOMMIT",
          "; COMMIT",
          "; /*...*/ ROLLBACK",
          "\uFEFF; END"
        ] do
      query = Exqlite.Query.build(statement: sql)
      assert {:error, %Exqlite.Error{}, ^state} = Connection.handle_execute(query, [], [], state)
    end

    assert state.transaction_status == :transaction
    {:ok, _, state} = Connection.handle_rollback([], state)
    Connection.disconnect(nil, state)
  end

  @tag server: [stream_expiry: 80]
  test "expired transactions fail and a fresh connection recovers", %{url: url} do
    repo(url)
    {:ok, state} = Connection.connect(turso_url: url, turso_provider: :bunny)
    {:ok, _, state} = Connection.handle_begin([], state)
    Process.sleep(150)
    query = Exqlite.Query.build(statement: "SELECT 1")

    assert {:disconnect, %DBConnection.ConnectionError{}, state} =
             Connection.handle_execute(query, [], [], state)

    Connection.disconnect(nil, state)
    assert %{rows: [[1]]} = Repo.query!("SELECT 1")
  end

  @tag server: [interactive: false]
  test "a service without interactive batons fails at connection", %{url: url} do
    assert {:error, %DBConnection.ConnectionError{message: message}} =
             Connection.connect(turso_url: url, turso_provider: :bunny)

    assert message =~ "interactive sessions"
    refute message =~ url
  end
end
