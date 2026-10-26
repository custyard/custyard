defmodule Custyard.Turso.ConnectionTest do
  # Each test runs its own server and repo, started as a dynamic repo.
  use ExUnit.Case, async: true

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Custyard.Turso.Connection
  alias Custyard.TursoTestServer

  @moduletag :tmp_dir
  @token "test-token"

  defmodule Repo do
    use Ecto.Repo, otp_app: :custyard, adapter: Custyard.Repo.Adapter
  end

  defmodule Item do
    use Ecto.Schema
    import Ecto.Changeset

    schema "items" do
      field :name, :string
      field :data, :binary
      field :count, :integer
      field :ratio, :float
      field :active, :boolean
      field :at, :utc_datetime_usec
      field :meta, :map
      field :tags, {:array, :string}
      field :price, :decimal
    end

    def changeset(item, attrs), do: item |> cast(attrs, [:name]) |> unique_constraint(:name)
  end

  setup context do
    server_opts =
      Keyword.merge(
        [database: Path.join(context.tmp_dir, "turso.db"), auth_token: @token],
        context[:server] || []
      )

    url = TursoTestServer.url(start_supervised!({TursoTestServer, server_opts}))

    repo =
      start_supervised!(
        {Repo, name: nil, turso_url: url, turso_auth_token: @token, pool_size: 2, log: false}
      )

    Repo.put_dynamic_repo(repo)

    for sql <- [
          """
          CREATE TABLE items (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, data BLOB,
            count INTEGER, ratio REAL, active INTEGER, at TEXT, meta TEXT, tags TEXT,
            price DECIMAL)
          """,
          "CREATE UNIQUE INDEX items_name_index ON items (name)",
          "CREATE TABLE parents (id INTEGER PRIMARY KEY)",
          """
          CREATE TABLE children (id INTEGER PRIMARY KEY,
            parent_id INTEGER NOT NULL REFERENCES parents (id) ON DELETE CASCADE)
          """
        ] do
      Repo.query!(sql)
    end

    %{url: url, repo: repo}
  end

  test "values round-trip through Ecto's SQLite types" do
    item =
      Repo.insert!(%Item{
        name: "everything",
        data: <<0, 255, 1>>,
        count: 9_223_372_036_854_775_807,
        ratio: 0.25,
        active: true,
        at: ~U[2026-10-26 09:30:00.123456Z],
        meta: %{"k" => [1, "two"]},
        tags: ["a", "b"],
        price: Decimal.new("12.50")
      })

    loaded = Repo.get!(Item, item.id)

    for field <- [:name, :data, :count, :ratio, :active, :at, :meta, :tags],
        do: assert(Map.fetch!(loaded, field) == Map.fetch!(item, field))

    assert Decimal.equal?(loaded.price, item.price)

    assert [^loaded] =
             Repo.all(from i in Item, where: i.at <= ^~U[2026-10-26 10:00:00Z] and i.active)
  end

  test "bulk writes report the rows they change" do
    assert {2, nil} = Repo.insert_all(Item, [%{name: "a"}, %{name: "b"}])

    assert {1, [%{name: "a!"}]} =
             Repo.update_all(from(i in Item, where: i.name == "a", select: i),
               set: [name: "a!"]
             )

    assert {2, nil} = Repo.delete_all(Item)
  end

  test "a unique violation becomes a changeset error" do
    assert {:ok, _} = %Item{} |> Item.changeset(%{name: "dup"}) |> Repo.insert()
    assert {:error, changeset} = %Item{} |> Item.changeset(%{name: "dup"}) |> Repo.insert()
    assert {"has already been taken", _} = changeset.errors[:name]
  end

  # The test server opens every stream with foreign keys off, as sqld does.
  test "foreign keys are enforced on every stream, in and out of transactions" do
    assert_raise Exqlite.Error, ~r/^FOREIGN KEY constraint failed/, fn ->
      Repo.query!("INSERT INTO children (parent_id) VALUES (999)")
    end

    Repo.transaction(fn ->
      assert {:error, %Exqlite.Error{message: "FOREIGN KEY constraint failed"}} =
               Repo.query("INSERT INTO children (parent_id) VALUES (999)")
    end)

    Repo.query!("INSERT INTO parents (id) VALUES (1)")
    Repo.query!("INSERT INTO children (parent_id) VALUES (1)")
    Repo.query!("DELETE FROM parents WHERE id = 1")
    assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM children")
  end

  test "transactions commit and roll back" do
    assert {:error, :undo} =
             Repo.transaction(fn ->
               Repo.insert!(%Item{name: "rolled back"})
               Repo.rollback(:undo)
             end)

    assert {:ok, _} = Repo.transaction(fn -> Repo.insert!(%Item{name: "committed"}) end)
    assert Repo.all(from i in Item, select: i.name) == ["committed"]
  end

  # Ecto aborts the whole transaction when a nested one rolls back; the SQL
  # sandbox is what nests with savepoints, through these callbacks.
  test "savepoints roll back inside a transaction", %{url: url} do
    insert = fn state, name ->
      query = Exqlite.Query.build(statement: "INSERT INTO items (name) VALUES (?)")
      {:ok, _, _, state} = Connection.handle_execute(query, [name], [], state)
      state
    end

    {:ok, state} = Connection.connect(turso_url: url, turso_auth_token: @token)
    {:ok, _, state} = Connection.handle_begin([mode: :transaction], state)
    state = insert.(state, "outer")
    {:ok, _, state} = Connection.handle_begin([mode: :savepoint], state)
    assert {:transaction, state} = Connection.handle_status([], state)
    state = insert.(state, "inner")
    {:ok, _, state} = Connection.handle_rollback([mode: :savepoint], state)
    assert {:transaction, state} = Connection.handle_status([], state)
    state = insert.(state, "after")
    {:ok, _, state} = Connection.handle_commit([mode: :transaction], state)
    assert {:idle, _state} = Connection.handle_status([], state)

    assert Repo.all(from i in Item, select: i.name, order_by: i.id) == ["outer", "after"]
  end

  test "uncommitted writes stay on their transaction's stream", %{repo: repo} do
    count_elsewhere = fn ->
      Task.async(fn ->
        Repo.put_dynamic_repo(repo)
        Repo.aggregate(Item, :count)
      end)
      |> Task.await()
    end

    Repo.transaction(fn ->
      Repo.insert!(%Item{name: "pending"})
      assert Repo.aggregate(Item, :count) == 1
      assert count_elsewhere.() == 0
    end)

    assert count_elsewhere.() == 1
  end

  test "Repo.stream reads every row" do
    Repo.insert_all(Item, [%{name: "a"}, %{name: "b"}, %{name: "c"}])

    assert {:ok, ["a", "b", "c"]} =
             Repo.transaction(fn ->
               from(i in Item, select: i.name, order_by: i.name)
               |> Repo.stream(max_rows: 1)
               |> Enum.to_list()
             end)
  end

  @tag server: [stream_expiry: 100]
  test "a transaction that outlives its stream fails as a connection error" do
    # The pool logs the disconnect.
    capture_log(fn ->
      assert_raise DBConnection.ConnectionError, ~r/Turso: HTTP 400/, fn ->
        Repo.transaction(fn ->
          Repo.insert!(%Item{name: "first"})
          Process.sleep(300)
          Repo.insert!(%Item{name: "second"})
        end)
      end
    end)

    assert Repo.aggregate(Item, :count) == 0
  end

  @tag server: [idle_timeout: 100]
  test "replaces an HTTP connection the server closed while idle", %{url: url} do
    {:ok, state} = Connection.connect(turso_url: url, turso_auth_token: @token)
    Process.sleep(300)
    {:ok, state} = Connection.ping(state)

    query = Exqlite.Query.build(statement: "SELECT 41 + 1")

    assert {:ok, _query, %Exqlite.Result{rows: [[42]]}, _state} =
             Connection.handle_execute(query, [], [], state)
  end

  test "a wrong token or an unreachable server fails at connect", %{url: url} do
    assert {:error, %DBConnection.ConnectionError{message: message}} =
             Connection.connect(turso_url: url, turso_auth_token: "wrong")

    assert message =~ "HTTP 401"

    assert {:error, %DBConnection.ConnectionError{message: message}} =
             Connection.connect(turso_url: "libsql://127.0.0.1:1?tls=0")

    assert message =~ "cannot connect to 127.0.0.1:1"
  end

  test "Ecto never creates or drops a Turso database", %{url: url} do
    adapter = Custyard.Repo.Adapter
    assert adapter.storage_up(turso_url: url) == {:error, :already_up}
    assert adapter.storage_status(turso_url: url) == :up
    assert {:error, message} = adapter.storage_down(turso_url: url)
    assert message =~ "turso db destroy"
  end
end
