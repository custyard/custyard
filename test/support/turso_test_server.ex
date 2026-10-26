defmodule Custyard.TursoTestServer do
  @moduledoc """
  A libSQL server for tests: Hrana 3 over HTTP in front of a local SQLite
  file, through Exqlite.

  It behaves like sqld where `Custyard.Turso.Connection` can tell: each
  stream is its own SQLite connection with SQLite's defaults (foreign keys
  off), the baton changes on every response, a stream expires when idle,
  an unknown baton is an HTTP 400, a bad token an HTTP 401, and SQLite
  errors keep sqld's "SQLite error: " prefix. It implements the requests
  the driver sends: `execute`, `get_autocommit` and `close`.

  With `route_streams: true` it also does what a server behind a load
  balancer does: a stream that stays open is answered with a `base_url` on
  a second listener, and only that listener takes its baton. With `:tls`
  it serves HTTPS, as Turso does.

  CI runs the suite against the real server image as well (see the `turso`
  job in `.github/workflows/ci.yml`). To run it over this server locally:

      MIX_ENV=test mix run --no-start -e 'Custyard.TursoTestServer.serve(port: 8089)'
      TURSO_TEST_URL='libsql://127.0.0.1:8089?tls=0' mix test
  """

  use Supervisor

  @doc """
  Options: `:database` (required), `:port` (default 0, any free port),
  `:auth_token` (default none: no auth), `:stream_expiry` (ms, default
  10_000), `:idle_timeout` (ms an idle HTTP connection stays open, default
  60_000), `:route_streams` (default false), `:tls` (`:ssl` options with
  the certificate and key for `localhost`; default none: plain HTTP).
  """
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @doc """
  The `libsql://` URL of a running server. Pass `tls: true` for a server
  started with `:tls`.
  """
  def url(server, opts \\ []) do
    if opts[:tls],
      do: "libsql://localhost:#{port(server, :bandit)}",
      else: "libsql://127.0.0.1:#{port(server, :bandit)}?tls=0"
  end

  @doc false
  def port(server, listener) do
    {_, bandit, _, _} =
      server |> Supervisor.which_children() |> List.keyfind(listener, 0)

    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)
    port
  end

  @doc """
  Runs a server in the foreground, for `mix run`. The database file is
  created if missing.
  """
  def serve(opts \\ []) do
    {:ok, _} = Application.ensure_all_started([:bandit, :exqlite, :jason])
    database = Keyword.get(opts, :database, Path.expand("tmp/turso_test.db"))
    File.mkdir_p!(Path.dirname(database))
    {:ok, server} = start_link(Keyword.put(opts, :database, database))
    IO.puts("Hrana test server for #{database} at #{url(server)}")
    Process.sleep(:infinity)
  end

  @impl Supervisor
  def init(opts) do
    database = Keyword.fetch!(opts, :database)

    # WAL lets streams read while another writes, as on sqld. The mode is
    # stored in the file, and switching it needs the file to itself.
    {:ok, db} = Exqlite.Sqlite3.open(database)
    :ok = Exqlite.Sqlite3.execute(db, "PRAGMA journal_mode = WAL")
    :ok = Exqlite.Sqlite3.close(db)

    config = %{
      database: database,
      auth_token: Keyword.get(opts, :auth_token),
      stream_expiry: Keyword.get(opts, :stream_expiry, 10_000),
      route_streams: Keyword.get(opts, :route_streams, false),
      tls: Keyword.get(opts, :tls),
      streams: :ets.new(:turso_test_streams, [:public, :set]),
      server: self()
    }

    listeners =
      if config.route_streams,
        do: [{:bandit, Keyword.get(opts, :port, 0)}, {:stream_bandit, 0}],
        else: [{:bandit, Keyword.get(opts, :port, 0)}]

    children =
      for {id, port} <- listeners do
        %{
          id: id,
          start:
            {Bandit, :start_link,
             [
               [
                 plug: {__MODULE__.Router, Map.put(config, :listener, id)},
                 scheme: if(config.tls, do: :https, else: :http),
                 ip: {127, 0, 0, 1},
                 port: port,
                 thousand_island_options: [
                   read_timeout: Keyword.get(opts, :idle_timeout, 60_000),
                   transport_options: config.tls || []
                 ]
               ]
             ]},
          type: :supervisor
        }
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule Custyard.TursoTestServer.Router do
  @moduledoc false

  @behaviour Plug

  import Plug.Conn

  alias Custyard.TursoTestServer.Stream

  @impl Plug
  def init(config), do: config

  @impl Plug
  def call(%{method: "POST", path_info: ["v3", "pipeline"]} = conn, config) do
    with :ok <- authorize(conn, config),
         {:ok, body, conn} <- read_body(conn, length: 64_000_000),
         {:ok, %{"requests" => requests} = pipeline} <- Jason.decode(body),
         {:ok, stream} <- stream(pipeline["baton"], config) do
      {results, open?} = Stream.run(stream, requests)
      baton = if open?, do: new_baton(stream, config)
      base_url = if open?, do: base_url(config)
      json(conn, 200, %{"baton" => baton, "base_url" => base_url, "results" => results})
    else
      :unauthorized ->
        json(conn, 401, %{
          "message" => "Authentication required",
          "code" => "AUTH_HEADER_NOT_FOUND"
        })

      :unknown_stream ->
        json(conn, 400, %{"message" => "Stream not found", "code" => "STREAM_EXPIRED"})

      {:error, reason} ->
        json(conn, 500, %{"message" => "Cannot open stream: #{inspect(reason)}"})

      _invalid ->
        json(conn, 400, %{"message" => "Invalid pipeline request"})
    end
  end

  def call(%{method: "GET", path_info: path} = conn, _config) when path in [["v3"], ["health"]],
    do: send_resp(conn, 200, "")

  def call(conn, _config), do: send_resp(conn, 404, "")

  defp authorize(_conn, %{auth_token: nil}), do: :ok

  defp authorize(conn, %{auth_token: token}) do
    if get_req_header(conn, "authorization") == ["Bearer " <> token],
      do: :ok,
      else: :unauthorized
  end

  defp stream(nil, config), do: Stream.start(config)

  # A routed stream is not known to the listener that opened it.
  defp stream(_baton, %{route_streams: true, listener: :bandit}), do: :unknown_stream

  defp stream(baton, %{streams: streams}) do
    # A baton is good for one request.
    case :ets.take(streams, baton) do
      [{^baton, pid}] -> if Process.alive?(pid), do: {:ok, pid}, else: :unknown_stream
      [] -> :unknown_stream
    end
  end

  defp base_url(%{route_streams: false}), do: nil

  defp base_url(config) do
    port = Custyard.TursoTestServer.port(config.server, :stream_bandit)
    if config.tls, do: "https://localhost:#{port}", else: "http://127.0.0.1:#{port}"
  end

  defp new_baton(stream, %{streams: streams}) do
    baton = Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
    :ets.insert(streams, {baton, stream})
    baton
  end

  defp json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end

defmodule Custyard.TursoTestServer.Stream do
  @moduledoc false

  # One Hrana stream: one SQLite connection, closed by a `close` request, by
  # sitting idle past the expiry, or when the server stops.

  use GenServer

  alias Exqlite.Sqlite3

  def start(config) do
    case GenServer.start(__MODULE__, config) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, reason}
    end
  end

  def run(stream, requests), do: GenServer.call(stream, {:run, requests}, :infinity)

  @impl true
  def init(config) do
    Process.monitor(config.server)
    {:ok, db} = Sqlite3.open(config.database)
    :ok = Sqlite3.set_busy_timeout(db, 30_000)
    {:ok, %{db: db, expiry: config.stream_expiry}, config.stream_expiry}
  end

  @impl true
  def handle_call({:run, requests}, _from, state) do
    {results, open?} =
      Enum.map_reduce(requests, true, fn
        %{"type" => "close"}, _open? -> {ok(%{"type" => "close"}), false}
        request, open? -> {handle_request(request, state.db), open?}
      end)

    if open? do
      {:reply, {results, true}, state, state.expiry}
    else
      {:stop, :normal, {results, false}, state}
    end
  end

  @impl true
  def handle_info(:timeout, state), do: {:stop, :normal, state}
  def handle_info({:DOWN, _, :process, _, _}, state), do: {:stop, :normal, state}

  @impl true
  def terminate(_reason, %{db: db}), do: Sqlite3.close(db)

  defp handle_request(%{"type" => "execute", "stmt" => stmt}, db) do
    case execute(db, stmt["sql"], Enum.map(stmt["args"] || [], &decode/1)) do
      {:ok, result} -> ok(%{"type" => "execute", "result" => result})
      {:error, reason} -> error("SQLite error: " <> to_string(reason), "SQLITE_ERROR")
    end
  end

  defp handle_request(%{"type" => "get_autocommit"}, db) do
    {:ok, status} = Sqlite3.transaction_status(db)
    ok(%{"type" => "get_autocommit", "is_autocommit" => status == :idle})
  end

  defp handle_request(request, _db),
    do: error("Unsupported request #{inspect(request["type"])}", "PROTOCOL_ERROR")

  defp execute(db, sql, args) do
    with {:ok, stmt} <- Sqlite3.prepare(db, sql) do
      try do
        with :ok <- bind(stmt, args),
             {:ok, columns} <- Sqlite3.columns(db, stmt),
             {:ok, rows} <- Sqlite3.fetch_all(db, stmt),
             {:ok, changes} <- Sqlite3.changes(db),
             {:ok, rowid} <- Sqlite3.last_insert_rowid(db) do
          {:ok,
           %{
             "cols" => Enum.map(columns, &%{"name" => &1, "decltype" => nil}),
             "rows" => Enum.map(rows, fn row -> Enum.map(row, &encode/1) end),
             "affected_row_count" => changes,
             "last_insert_rowid" => Integer.to_string(rowid)
           }}
        end
      after
        Sqlite3.release(db, stmt)
      end
    end
  end

  defp bind(stmt, args) do
    Sqlite3.bind(stmt, args)
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  defp decode(%{"type" => "null"}), do: nil
  defp decode(%{"type" => "integer", "value" => value}), do: String.to_integer(value)
  defp decode(%{"type" => "float", "value" => value}), do: value / 1
  defp decode(%{"type" => "text", "value" => value}), do: value

  defp decode(%{"type" => "blob", "base64" => data}),
    do: {:blob, Base.decode64!(data, padding: false)}

  defp encode(nil), do: %{"type" => "null"}

  defp encode(int) when is_integer(int),
    do: %{"type" => "integer", "value" => Integer.to_string(int)}

  defp encode(float) when is_float(float), do: %{"type" => "float", "value" => float}

  # Exqlite returns TEXT and BLOB alike as binaries; a binary that is not
  # UTF-8 can only travel as a blob.
  defp encode(data) when is_binary(data) do
    if String.valid?(data),
      do: %{"type" => "text", "value" => data},
      else: %{"type" => "blob", "base64" => Base.encode64(data)}
  end

  defp ok(response), do: %{"type" => "ok", "response" => response}

  defp error(message, code),
    do: %{"type" => "error", "error" => %{"message" => message, "code" => code}}
end
