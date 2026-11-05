defmodule Custyard.Turso.Connection do
  @moduledoc """
  A `DBConnection` to a Turso or Bunny (libSQL) database over HTTP.

  It speaks Exqlite's terms to `Ecto.Adapters.SQLite3`'s SQL layer: it takes
  `Exqlite.Query` structs and returns `Exqlite.Result` and `Exqlite.Error`.
  SQL generation, type loading and constraint errors are therefore the ones
  the local SQLite path uses, and rows written by either read back the same.
  `Custyard.Repo.Adapter` picks this module when the Repo is configured with
  `:turso_url`.

  ## Streams

  The server runs each Hrana stream on its own SQLite connection. Outside a
  transaction, a statement opens a stream and closes it in the same HTTP
  request: one round trip, nothing held on the server. A transaction keeps
  its stream from BEGIN to COMMIT or ROLLBACK, passing the baton from one
  request to the next. The server expires a stream left idle for a few
  seconds, which ends its transaction, so keep transactions short.

  A new stream starts with SQLite's defaults, so each one first runs
  `PRAGMA foreign_keys = ON`, the setting Exqlite applies to every local
  connection, in the same request.

  ## Options

    * `:turso_url` - required. A `libsql://` URL; `?tls=0` selects plain HTTP
      for a local libSQL server. `https://` and `http://` also work.
    * `:turso_auth_token` - the database token, sent as a bearer token.
    * `:turso_provider` - `:turso` (default, Hrana v3) or `:bunny` (v2).
      Bunny checks interactive sessions at connect and wraps standalone
      statements in conditional transactions so reads reach the primary.
      A reserved savepoint guards explicit transactions: a statement that
      automatically rolls back cannot make later statements commit alone.
    * `:foreign_keys` - `:on` (default) or `:off`.
    * `:default_transaction_mode` - `:deferred` (default), `:immediate` or
      `:exclusive`, as for `Ecto.Adapters.SQLite3`.
    * `:connect_timeout` - milliseconds to open the HTTP connection
      (default 5000).
    * `:transport_opts` - socket options for Mint, such as `cacertfile:` for
      a server whose certificate the system CAs do not sign. TLS stays
      verified unless they say otherwise.
  """

  use DBConnection

  alias Custyard.Turso.{HTTP, Protocol}
  alias DBConnection.ConnectionError
  alias Exqlite.{Error, Query, Result}

  defstruct [
    :http,
    :endpoint,
    :stream_endpoint,
    :baton,
    :headers,
    :setup,
    provider: :turso,
    protocol: :v3,
    default_transaction_mode: :deferred,
    transaction_status: :idle
  ]

  @default_timeout 15_000

  @impl true
  def connect(opts) do
    with {:ok, endpoint} <- endpoint(opts),
         {:ok, http} <- open(endpoint, opts) do
      state = %__MODULE__{
        http: http,
        endpoint: endpoint,
        headers: headers(opts),
        setup: setup(opts),
        provider: Keyword.get(opts, :turso_provider, :turso),
        protocol: protocol(opts),
        default_transaction_mode: Keyword.get(opts, :default_transaction_mode, :deferred)
      }

      # A wrong URL or token fails here, reported by DBConnection as a
      # connection error, instead of on the first query.
      case run(state, [Protocol.execute("SELECT 1", [])], opts) do
        {:ok, _responses, state} ->
          check_interactive(state, opts)

        {:error, error, state} ->
          HTTP.close(state.http)
          {:error, connection_error(Protocol.error_message(error))}

        {:disconnect, error, state} ->
          HTTP.close(state.http)
          {:error, error}
      end
    end
  end

  defp endpoint(opts) do
    case Protocol.parse_url(Keyword.fetch!(opts, :turso_url), protocol(opts)) do
      {:ok, endpoint} -> {:ok, endpoint}
      {:error, message} -> {:error, connection_error(message)}
    end
  end

  defp protocol(opts), do: if(Keyword.get(opts, :turso_provider) == :bunny, do: :v2, else: :v3)

  # Bunny's SQL API requires account support for interactive sessions. Fail
  # before migrations if batons cannot span requests, without writing data.
  defp check_interactive(%{provider: :turso} = state, _opts), do: {:ok, state}

  defp check_interactive(state, opts) do
    with {:ok, _, state} <- handle_begin([], state),
         {:ok, _, state} <- run(state, [Protocol.execute("SELECT 1", [])], opts),
         {:ok, _, state} <- handle_rollback([], state) do
      {:ok, state}
    else
      {_, _error, state} ->
        HTTP.close(state.http)

        {:error,
         connection_error(
           "Bunny Database requires working interactive sessions (batons); verify database access and session support"
         )}
    end
  end

  defp open(endpoint, opts) do
    case HTTP.connect(endpoint, opts) do
      {:ok, http} ->
        {:ok, http}

      {:error, error} ->
        {:error,
         connection_error(
           "cannot connect to #{endpoint.host}:#{endpoint.port}: #{Exception.message(error)}"
         )}
    end
  end

  defp headers(opts) do
    auth =
      case Keyword.get(opts, :turso_auth_token) do
        token when is_binary(token) and token != "" -> [{"authorization", "Bearer " <> token}]
        _ -> []
      end

    [{"content-type", "application/json"}, {"user-agent", "custyard"} | auth]
  end

  defp setup(opts) do
    case Keyword.get(opts, :foreign_keys, :on) do
      :on -> [Protocol.execute("PRAGMA foreign_keys = ON", [])]
      :off -> [Protocol.execute("PRAGMA foreign_keys = OFF", [])]
    end
  end

  @impl true
  def disconnect(_error, state) do
    # An open stream is left to expire on the server; this connection can no
    # longer reach it.
    HTTP.close(state.http)
  end

  @impl true
  def checkout(state), do: {:ok, state}

  @impl true
  def ping(state) do
    case HTTP.check(state.http) do
      {:ok, http} ->
        {:ok, %{state | http: http}}

      {:error, http, error} ->
        {:disconnect, connection_error(Exception.message(error)), %{state | http: http}}
    end
  end

  ## Queries

  @impl true
  def handle_prepare(%Query{} = query, opts, state) do
    {:ok, %{put_command(query, opts) | ref: make_ref()}, state}
  end

  @impl true
  def handle_execute(%Query{} = query, params, opts, state) do
    query = put_command(query, opts)
    sql = IO.iodata_to_binary(query.statement)

    with :ok <- allow_statement(sql, state),
         {:ok, args} <- encode_args(params, sql, state),
         {:ok, [response], state} <-
           statement(run(state, [Protocol.execute(sql, args)], opts), sql) do
      case Protocol.statement_result(response) do
        {:ok, columns, rows, affected} ->
          {:ok, query, result(query, columns, rows, affected), state}

        {:error, message} ->
          {:disconnect, connection_error(message), state}
      end
    end
  end

  # V2 cannot inspect autocommit after arbitrary SQL transaction control. Only the
  # DBConnection transaction callbacks may end a transaction; otherwise a
  # later statement could silently commit after a caller-issued COMMIT.
  defp allow_statement(sql, %{protocol: :v2} = state) do
    if Regex.match?(
         ~r/\A(?:\s|;|\x{FEFF}|--[^\n]*(?:\n|$)|\/\*.*?\*\/)*(?:BEGIN|COMMIT|END|ROLLBACK|SAVEPOINT|RELEASE)\b/isu,
         sql
       ),
       do:
         {:error,
          %Error{
            message: "Use Ecto transaction callbacks for Bunny transaction control",
            statement: sql
          }, state},
       else: :ok
  end

  defp allow_statement(_sql, _state), do: :ok

  defp put_command(query, opts) do
    case Keyword.get(opts, :command) do
      nil -> query
      command -> %{query | command: command}
    end
  end

  defp encode_args(params, sql, state) do
    case Protocol.encode_args(params) do
      {:ok, args} -> {:ok, args}
      {:error, message} -> {:error, %Error{message: message, statement: sql}, state}
    end
  end

  defp statement({:error, error, state}, sql),
    do: {:error, %Error{message: Protocol.error_message(error), statement: sql}, state}

  defp statement(other, _sql), do: other

  # Mirrors Exqlite.Connection: a write reports the rows it changed, and its
  # rows only when it has a RETURNING clause.
  defp result(%Query{command: command}, columns, rows, affected)
       when command in [:insert, :update, :delete] do
    %Result{command: :execute, num_rows: affected, rows: if(columns == [], do: nil, else: rows)}
  end

  defp result(_query, columns, rows, _affected) do
    %Result{command: :execute, columns: columns, rows: rows, num_rows: length(rows)}
  end

  @impl true
  def handle_close(_query, _opts, state), do: {:ok, nil, state}

  # Streaming reads the whole result up front: a statement runs within one
  # request, so there is no server-side cursor to page through.
  @impl true
  def handle_declare(%Query{} = query, params, opts, state) do
    case handle_execute(query, params, opts, state) do
      {:ok, query, %Result{rows: rows}, state} -> {:ok, query, rows || [], state}
      other -> other
    end
  end

  @impl true
  def handle_fetch(_query, rows, _opts, state) do
    {:halt, %Result{command: :fetch, rows: rows, num_rows: length(rows)}, state}
  end

  @impl true
  def handle_deallocate(_query, _rows, _opts, state), do: {:ok, nil, state}

  ## Transactions
  #
  # Statements and the savepoint name follow Exqlite.Connection, so nested
  # transactions behave as they do against a local database.

  @impl true
  def handle_begin(opts, %{transaction_status: status} = state) do
    case Keyword.get(opts, :mode, state.default_transaction_mode) do
      mode when mode in [:deferred, :transaction] and status == :idle ->
        transaction(:begin, begin_statements("BEGIN TRANSACTION", opts), :keep, state, opts)

      :immediate when status == :idle ->
        transaction(
          :begin,
          begin_statements("BEGIN IMMEDIATE TRANSACTION", opts),
          :keep,
          state,
          opts
        )

      :exclusive when status == :idle ->
        transaction(
          :begin,
          begin_statements("BEGIN EXCLUSIVE TRANSACTION", opts),
          :keep,
          state,
          opts
        )

      mode
      when mode in [:deferred, :immediate, :exclusive, :savepoint] and status == :transaction ->
        transaction(:begin, ["SAVEPOINT exqlite_savepoint"], :keep, state, opts)
    end
  end

  # A standalone PRAGMA runs on a short-lived Hrana stream. Schema rebuilds
  # must disable foreign keys on the very stream that starts BEGIN, before
  # the transaction opens; issuing the PRAGMA inside BEGIN has no effect.
  # The migration checks foreign_key_check before committing. The stream
  # closes after COMMIT/ROLLBACK, so ordinary queries keep enforcement on.
  defp begin_statements(statement, opts) do
    if Keyword.get(opts, :migration_foreign_keys) == :off,
      do: ["PRAGMA foreign_keys = OFF", statement],
      else: [statement]
  end

  @impl true
  def handle_commit(opts, state) do
    case Keyword.get(opts, :mode, :deferred) do
      :savepoint ->
        transaction(
          :commit_savepoint,
          ["RELEASE SAVEPOINT exqlite_savepoint"],
          :keep,
          state,
          opts
        )

      _mode ->
        transaction(:commit, ["COMMIT"], :close, state, opts)
    end
  end

  @impl true
  def handle_rollback(opts, state) do
    case Keyword.get(opts, :mode, :deferred) do
      :savepoint ->
        transaction(
          :rollback_savepoint,
          ["ROLLBACK TO SAVEPOINT exqlite_savepoint", "RELEASE SAVEPOINT exqlite_savepoint"],
          :keep,
          state,
          opts
        )

      _mode ->
        transaction(:rollback, ["ROLLBACK TRANSACTION"], :close, state, opts)
    end
  end

  @impl true
  def handle_status(_opts, state), do: {state.transaction_status, state}

  defp transaction(call, statements, trailer, state, opts) do
    requests = Enum.map(statements, &Protocol.execute(&1, []))

    case run(state, requests, Keyword.put(opts, :turso_transition, true), trailer) do
      {:ok, _responses, state} ->
        {:ok, %Result{command: call, rows: [], columns: [], num_rows: 0}, state}

      {:error, error, state} ->
        message = Protocol.error_message(error)
        {:disconnect, %Error{message: message, statement: Enum.join(statements, "; ")}, state}

      {:disconnect, _error, _state} = disconnect ->
        disconnect
    end
  end

  ## Pipelines

  # Sends `statements` as one pipeline. A new stream is set up first; the
  # stream is then closed (`:close`) or kept for the transaction (`:keep`),
  # in which case the server also reports whether SQLite is still in it:
  # SQLite rolls back on its own after some errors.
  defp run(state, statements, opts, trailer \\ nil)

  defp run(%{provider: :bunny, transaction_status: :idle} = state, statements, opts, trailer)
       when trailer in [nil, :close] do
    requests = state.setup ++ [Protocol.primary_batch(statements), Protocol.close()]

    with {:ok, response, state} <- pipeline(state, requests, opts) do
      {setup_results, rest} = Enum.split(response.results, length(state.setup))

      with :ok <- check_setup(setup_results, state) do
        primary_result(rest, end_stream(state))
      end
    end
  end

  defp run(%{protocol: :v2, transaction_status: status} = state, statements, opts, trailer)
       when trailer == :keep or (is_nil(trailer) and status == :transaction) do
    setup = if state.baton, do: [], else: state.setup

    {batch, offset} =
      Protocol.guarded_batch(statements, opts[:turso_transition] == true, status == :transaction)

    with {:ok, response, state} <- pipeline(state, setup ++ [batch], opts) do
      {setup_results, rest} = Enum.split(response.results, length(setup))

      with :ok <- check_setup(setup_results, state) do
        guarded_result(
          rest,
          response,
          state,
          offset,
          length(statements),
          length(batch["batch"]["steps"])
        )
      end
    end
  end

  defp run(state, statements, opts, trailer) do
    trailer = trailer || if state.transaction_status == :transaction, do: :keep, else: :close
    setup = if state.baton, do: [], else: state.setup
    requests = setup ++ statements ++ trailer_requests(trailer, state.protocol)

    with {:ok, response, state} <- pipeline(state, requests, opts) do
      {setup_results, rest} = Enum.split(response.results, length(setup))
      {statement_results, trailer_results} = Enum.split(rest, length(statements))
      trailer_result = List.first(trailer_results)

      failed =
        Enum.find_value(statement_results, fn
          {:error, error} -> error
          {:ok, _response} -> nil
        end)

      with :ok <- check_setup(setup_results, state),
           {:ok, state} <- after_trailer(trailer, trailer_result, response, failed, state) do
        if failed,
          do: {:error, failed, state},
          else: {:ok, Enum.map(statement_results, fn {:ok, response} -> response end), state}
      end
    end
  end

  defp primary_result(
         [{:ok, %{"type" => "batch", "result" => result}}, {:ok, %{"type" => "close"}}],
         state
       ) do
    errors = result["step_errors"] || []

    case Enum.find(errors, &is_map/1) do
      nil ->
        case result["step_results"] do
          [begin_result, statement, commit_result]
          when is_map(begin_result) and is_map(statement) and is_map(commit_result) ->
            {:ok, [%{"type" => "execute", "result" => statement}], state}

          _ ->
            {:disconnect, connection_error("Bunny primary transaction did not complete"), state}
        end

      error ->
        {:error, error, state}
    end
  end

  defp primary_result(_results, state),
    do: {:disconnect, connection_error("Bunny primary transaction failed"), state}

  defp guarded_result(
         [{:ok, %{"type" => "batch", "result" => result}}],
         response,
         state,
         offset,
         count,
         expected
       ) do
    results = result["step_results"] || []
    errors = result["step_errors"] || []

    if valid_guard?(results, errors, expected, response.baton) do
      state = %{
        state
        | baton: response.baton,
          stream_endpoint: stream_endpoint(response.base_url, state),
          transaction_status: :transaction
      }

      case Enum.find(Enum.slice(errors, offset, count), &is_map/1) do
        nil ->
          guarded_statements(Enum.slice(results, offset, count), count, response, state)

        error ->
          {:error, error, state}
      end
    else
      {:disconnect, connection_error("Bunny transaction ended or interactive session was lost"),
       abandon_stream(response, state)}
    end
  end

  defp guarded_result(_results, response, state, _offset, _count, _expected),
    do:
      {:disconnect, connection_error("Bunny transaction guard failed"),
       abandon_stream(response, state)}

  defp valid_guard?(results, errors, expected, baton) do
    length(results) == expected and length(errors) == expected and
      is_map(List.last(results)) and is_binary(baton) and baton != ""
  end

  defp guarded_statements(statements, count, response, state) do
    if length(statements) == count and Enum.all?(statements, &is_map/1),
      do: {:ok, Enum.map(statements, &%{"type" => "execute", "result" => &1}), state},
      else:
        {:disconnect, connection_error("Bunny transaction response is incomplete"),
         abandon_stream(response, state)}
  end

  defp trailer_requests(:close, _protocol), do: [Protocol.close()]
  defp trailer_requests(:keep, :v2), do: []
  defp trailer_requests(:keep, :v3), do: [Protocol.get_autocommit()]

  defp check_setup(results, state) do
    case Enum.find(results, &match?({:error, _}, &1)) do
      nil ->
        :ok

      {:error, error} ->
        message = "stream setup failed: " <> Protocol.error_message(error)
        {:disconnect, connection_error(message), end_stream(state)}
    end
  end

  defp after_trailer(:close, {:ok, _close}, _response, _failed, state),
    do: {:ok, end_stream(state)}

  defp after_trailer(:keep, {:ok, %{"is_autocommit" => false}}, response, _failed, state)
       when is_binary(response.baton) do
    {:ok,
     %{
       state
       | baton: response.baton,
         stream_endpoint: stream_endpoint(response.base_url, state),
         transaction_status: :transaction
     }}
  end

  # SQLite is out of the transaction. After a failed BEGIN there was none to
  # leave. Inside one, SQLite rolled it back on its own (an OR ROLLBACK
  # conflict, a full disk) or a statement ended it, and the statements still
  # to come would each commit on their own, whatever the caller's transaction
  # does next. Disconnecting fails them instead. Either way the stream is
  # abandoned and expires on the server.
  defp after_trailer(:keep, {:ok, %{"is_autocommit" => true}}, _response, failed, state) do
    if state.transaction_status == :transaction do
      reason = if failed, do: ": " <> Protocol.error_message(failed), else: ""
      {:disconnect, connection_error("SQLite ended the transaction" <> reason), end_stream(state)}
    else
      {:ok, end_stream(state)}
    end
  end

  defp after_trailer(_trailer, result, _response, _failed, state) do
    message = "stream lost: #{inspect(result)}"
    {:disconnect, connection_error(message), end_stream(state)}
  end

  defp end_stream(state),
    do: %{state | baton: nil, stream_endpoint: nil, transaction_status: :idle}

  defp abandon_stream(%{baton: baton} = response, state) when is_binary(baton) do
    state = %{state | baton: baton, stream_endpoint: stream_endpoint(response.base_url, state)}

    case pipeline(state, [Protocol.close()], []) do
      {_, _, state} -> end_stream(state)
    end
  end

  defp abandon_stream(_response, state), do: end_stream(state)

  # The server may route the rest of a stream to another URL.
  defp stream_endpoint(nil, state), do: state.stream_endpoint

  defp stream_endpoint(base_url, state) do
    case Protocol.parse_url(base_url, state.protocol) do
      {:ok, endpoint} -> endpoint
      {:error, _} -> state.stream_endpoint
    end
  end

  defp pipeline(state, requests, opts) do
    endpoint = state.stream_endpoint || state.endpoint
    body = Protocol.encode_pipeline(state.baton, requests)
    path = Protocol.pipeline_path(endpoint, state.protocol)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case HTTP.post(state.http, endpoint, path, state.headers, body, timeout) do
      {:ok, http, 200, body} ->
        decode_response(body, length(requests), %{state | http: http})

      {:ok, http, status, body} ->
        {:disconnect, connection_error(Protocol.http_error(status, body)),
         end_stream(%{state | http: http})}

      {:error, http, error} ->
        {:disconnect, connection_error(Exception.message(error)),
         end_stream(%{state | http: http})}
    end
  end

  defp decode_response(body, count, state) do
    case Protocol.decode_pipeline(body) do
      {:ok, %{results: results} = response} when length(results) == count ->
        {:ok, response, state}

      {:ok, %{results: results}} ->
        message = "pipeline returned #{length(results)} results for #{count} requests"
        {:disconnect, connection_error(message), end_stream(state)}

      {:error, message} ->
        {:disconnect, connection_error(message), end_stream(state)}
    end
  end

  defp connection_error(message), do: ConnectionError.exception("Turso: " <> message)
end
