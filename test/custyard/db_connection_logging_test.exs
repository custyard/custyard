defmodule Custyard.DBConnectionLoggingTest.Handler do
  alias Custyard.Log.Formatter

  def adding_handler(config), do: {:ok, config}
  def removing_handler(_config), do: :ok
  def changing_config(_action, _old, new), do: {:ok, new}

  def log(%{meta: %{mfa: {DBConnection.Connection, :handle_event, 4}}} = event, %{
        config: %{owner: owner, ref: ref}
      }) do
    json = event |> Formatter.format(%{}) |> IO.iodata_to_binary()
    send(owner, {:db_connection_log, ref, event, json})
    :ok
  end

  def log(_event, _config), do: :ok
end

defmodule Custyard.DBConnectionLoggingTest.Driver do
  # Only the callbacks exercised here are implemented. `use DBConnection` declares
  # the entire behaviour but supplies no defaults for unused query callbacks.
  def connect(opts) do
    state = %{
      owner: Keyword.fetch!(opts, :owner),
      private: Keyword.fetch!(opts, :private)
    }

    Logger.metadata(email: state.private, raw_payload: state.private, driver_state: state)
    send(state.owner, {:driver_connect, self()})

    case Keyword.fetch!(opts, :connect_result) do
      :ok -> {:ok, state}
      {:error, exception} -> {:error, exception}
    end
  end

  def checkout(state), do: {:ok, state}
  def ping(state), do: {:ok, state}

  def handle_status(opts, state) do
    case Keyword.get(opts, :disconnect_with) do
      nil -> {:idle, state}
      exception -> {:disconnect, exception, state}
    end
  end

  def disconnect(_exception, state) do
    send(state.owner, {:driver_disconnected, self()})
    :ok
  end
end

defmodule Custyard.DBConnectionLoggingTest do
  use ExUnit.Case, async: false

  alias Custyard.DBConnectionLoggingTest.{Driver, Handler}

  @handler :custyard_db_connection_logging_test
  @private "DB-LOG-PRIVATE-CANARY person-private@example.test " <>
             "https://db-private.example.test/login/verify/secret-token?token=private-token " <>
             "SELECT private_body FROM private_messages; password=private-password " <>
             "\r\nFORGED EVENT"
  @private_fragments [
    "DB-LOG-PRIVATE-CANARY",
    "person-private@example.test",
    "https://db-private.example.test",
    "secret-token",
    "private-token",
    "SELECT",
    "private_body",
    "private_messages",
    "password",
    "private-password",
    "FORGED EVENT"
  ]

  setup do
    assert List.keymember?(:logger.get_primary_config()[:filters], :custyard_log_privacy, 0)
    previous = Logger.get_module_level([DBConnection.Connection])
    Logger.put_module_level(DBConnection.Connection, :debug)

    on_exit(fn ->
      Logger.delete_module_level(DBConnection.Connection)
      Enum.each(previous, fn {module, level} -> Logger.put_module_level(module, level) end)
    end)

    ref = make_ref()

    assert :ok =
             :logger.add_handler(@handler, Handler, %{
               level: :debug,
               config: %{owner: self(), ref: ref}
             })

    on_exit(fn -> :logger.remove_handler(@handler) end)
    %{log_ref: ref}
  end

  test "failed connect preserves the connection exception category without its payload",
       context do
    exception = %DBConnection.ConnectionError{message: "connection refused; " <> @private}
    assert_failed_connect(context, exception, "unreachable")
  end

  test "failed connect preserves another real exception class", context do
    exception = %RuntimeError{message: "HTTP 403 forbidden; " <> @private}
    assert_failed_connect(context, exception, "auth_rejected")
  end

  test "failed connect classifies a SQLite exception without its statement", context do
    exception = %Exqlite.Error{message: "database is locked; " <> @private, statement: @private}
    assert_failed_connect(context, exception, "locked")
  end

  test "failed connect classifies a Mint exception without a message field", context do
    exception = %Mint.TransportError{reason: :protocol_not_negotiated}
    assert_failed_connect(context, exception, "unreachable")
  end

  test "real Mint disconnect retains the boot probe's class-based category", context do
    exception = %Mint.HTTPError{reason: {:unexpected_data, @private}}
    assert_disconnect(context, exception, :error, "unreachable")
  end

  test "real disconnect preserves warning severity without its banner or state", context do
    exception = %DBConnection.ConnectionError{
      message: "connection refused; " <> @private,
      severity: :warning
    }

    assert_disconnect(context, exception, :warning, "unreachable")
  end

  test "real SQLite disconnect preserves the locked category without its statement", context do
    exception = %Exqlite.Error{message: "database is locked; " <> @private, statement: @private}
    assert_disconnect(context, exception, :error, "locked")
  end

  defp assert_failed_connect(context, exception, category) do
    with_pool({:error, exception}, fn _pool ->
      assert_receive {:driver_connect, connection}, 1_000
      assert_safe_log(context, connection, exception, :error, "connect", category)
    end)
  end

  defp assert_disconnect(context, exception, level, category) do
    with_pool(:ok, fn pool ->
      assert_receive {:driver_connect, connection}, 1_000
      assert_receive {:connected, ^connection}, 1_000

      assert DBConnection.status(pool, disconnect_with: exception, timeout: 1_000) == :error
      assert_receive {:driver_disconnected, ^connection}, 1_000
      assert_safe_log(context, connection, exception, level, "disconnect", category)
    end)
  end

  defp with_pool(connect_result, fun) do
    {:ok, pool} =
      DBConnection.start_link(Driver,
        owner: self(),
        private: @private,
        connect_result: connect_result,
        connection_listeners: [self()],
        pool_size: 1,
        backoff_min: 60_000,
        backoff_max: 60_000
      )

    try do
      fun.(pool)
    after
      Supervisor.stop(pool)
    end
  end

  defp assert_safe_log(%{log_ref: ref}, connection, exception, level, stage, category) do
    assert_receive {:db_connection_log, ^ref, %{meta: %{pid: ^connection}} = event, json}, 1_000

    assert event.level == level
    assert event.msg == {:string, "external_log"}
    assert event.meta.mfa == {DBConnection.Connection, :handle_event, 4}

    record = Jason.decode!(json)
    assert record["event"] == "external_log"
    assert record["level"] == Atom.to_string(level)

    assert record["service"] == "custyard"
    assert record["schema_version"] == 1
    assert String.ends_with?(json, "\n")
    assert length(String.split(json, "\n", trim: true)) == 1
    refute json =~ "\r"

    for key <- [
          :crash_reason,
          :report_cb,
          :state,
          :driver_state,
          :email,
          :url,
          :raw_payload,
          :statement,
          :exception,
          :message
        ] do
      refute Map.has_key?(event.meta, key)
      refute Map.has_key?(record, Atom.to_string(key))
    end

    handler_payload = inspect(event, limit: :infinity, printable_limit: :infinity)

    for private <- @private_fragments do
      refute handler_payload =~ private
      refute json =~ private
    end

    error_type = Atom.to_string(exception.__struct__)

    assert %{
             stage: ^stage,
             reason: "exception",
             error_type: ^error_type,
             database_category: ^category
           } = event.meta

    assert %{
             "stage" => ^stage,
             "reason" => "exception",
             "error_type" => ^error_type,
             "database_category" => ^category
           } = record
  end
end
