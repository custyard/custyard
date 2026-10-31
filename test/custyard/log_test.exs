defmodule Custyard.LogTest.Handler do
  alias Custyard.Log.Formatter
  def adding_handler(config), do: {:ok, config}
  def removing_handler(_config), do: :ok
  def changing_config(_action, _old, new), do: {:ok, new}

  def log(event, %{config: %{owner: owner}}) do
    send(
      owner,
      {:policy_log, event, Formatter.format(event, %{}) |> IO.iodata_to_binary()}
    )
  end
end

defmodule Custyard.LogTest do
  use ExUnit.Case, async: false

  alias Custyard.Acknowledgments.Consumer
  alias Custyard.Log.Formatter

  require Custyard.Log, as: Log
  require Logger
  import ExUnit.CaptureLog

  @canary "PRIVATE-CANARY-person@example.test-/operator/login/verify/credential\r\nFORGED EVENT"

  setup do
    previous = Logger.metadata()
    levels = Logger.get_module_level([__MODULE__])
    Logger.put_module_level(__MODULE__, :debug)

    on_exit(fn ->
      Logger.delete_module_level(__MODULE__)
      Enum.each(levels, fn {module, level} -> Logger.put_module_level(module, level) end)
    end)

    on_exit(fn -> Logger.reset_metadata(previous) end)
    :ok
  end

  test "metadata is an explicit typed allowlist and malformed values do not poison safe fields" do
    safe =
      Custyard.Log.sanitize_metadata(%{
        operator_id: 12,
        tenant_id: 4,
        message_id: 99,
        provider_status: 422,
        reason: :unknown_account,
        provider_code: "validation_failed",
        validation_fields: ["from", "to", @canary],
        error_code: "http_422",
        email: @canary,
        sender: @canary,
        recipient: @canary,
        peer: @canary,
        arbitrary: %{body: @canary},
        request_id: <<255>>,
        route: @canary,
        operation_id: Custyard.Log.new_id(),
        error_type: RuntimeError
      })

    assert safe.operator_id == 12
    assert safe.tenant_id == 4
    assert safe.message_id == 99
    assert safe.provider_status == 422
    assert safe.validation_fields == ["from", "to"]
    assert safe.reason == "unknown_account"
    assert safe.provider_code == "validation_failed"
    assert safe.error_code == "http_422"
    assert safe.error_type == "Elixir.RuntimeError"
    refute Map.has_key?(safe, :email)
    refute Map.has_key?(safe, :request_id)
    refute Map.has_key?(safe, :route)
    refute inspect(safe) =~ @canary
    assert Custyard.Log.sanitize_metadata(safe) == safe
    assert Custyard.Log.sanitize_metadata([@canary]) == %{}
  end

  test "provider diagnostics retain only known codes and validation field names" do
    error =
      {422,
       %{
         "error" => %{
           "code" => "validation_failed",
           "details" => %{
             "from" => [@canary],
             "to.0" => [@canary],
             @canary => [@canary]
           }
         },
         "message" => @canary,
         "headers" => %{"authorization" => @canary}
       }}

    assert Custyard.Log.failure(error) == [
             reason: :provider_response,
             provider_status: 422,
             provider_code: "validation_failed",
             validation_fields: ["from", "to"]
           ]

    assert Custyard.Log.failure({:api_error, 422, %{"code" => "validation_failed"}}) == [
             reason: :provider_response,
             provider_status: 422,
             provider_code: "validation_failed"
           ]

    assert Custyard.Log.failure({:request_failed, %RuntimeError{message: @canary}}) == [
             reason: :exception,
             error_type: RuntimeError
           ]

    assert Custyard.Log.failure({:provider_status, 422}) == [
             reason: :provider_response,
             provider_status: 422
           ]

    assert Custyard.Log.failure({:provider_status, 999}) == [reason: :unclassified_error]

    assert Custyard.Log.failure({:parse_failed, %RuntimeError{message: @canary}}) == [
             reason: :exception,
             error_type: RuntimeError
           ]

    assert Map.new(Custyard.Log.failure({:exit, @canary})) == %{
             reason: :unclassified_error,
             error_type: :exit
           }

    assert Map.new(Custyard.Log.failure({:throw, @canary})) == %{
             reason: :unclassified_error,
             error_type: :throw
           }

    assert Custyard.Log.failure("invalid signature") == [reason: :invalid_signature]
    assert Custyard.Log.failure("invalid signature " <> @canary) == [reason: :unclassified_error]

    assert Custyard.Log.failure({422, %{"code" => @canary, "errors" => %{}}}) == [
             reason: :provider_response,
             provider_status: 422
           ]

    assert Custyard.Log.failure({:timeout, @canary}) == [reason: :timeout]
    assert Custyard.Log.failure({:private_failure, @canary}) == [reason: :unclassified_error]

    assert Custyard.Log.failure(%RuntimeError{message: @canary}) == [
             reason: :exception,
             error_type: RuntimeError
           ]

    assert Custyard.Log.failure({:error, {:error, {:error, {:error, {:error, @canary}}}}}) == [
             reason: :unclassified_error
           ]

    assert Custyard.Log.failure(%Ecto.Changeset{errors: :invalid}) == [
             reason: :unclassified_error
           ]
  end

  test "all message/report forms fail closed and filtering is idempotent" do
    for message <- [
          {:string, @canary},
          {~c"~p", [@canary]},
          {:report, %{state: @canary, reason: {%RuntimeError{message: @canary}, []}}},
          {:report, [secret: @canary]},
          {:string, <<255>>}
        ] do
      raw = %{
        level: :error,
        msg: message,
        meta: %{
          time: System.system_time(:microsecond),
          email: @canary,
          headers: @canary,
          arbitrary: @canary,
          mfa: {__MODULE__, :__info__, 1}
        }
      }

      safe = Custyard.Log.filter(raw, nil)
      assert safe.msg == {:string, "external_log"}
      refute inspect(safe) =~ @canary
      assert Custyard.Log.filter(safe, nil) == safe
      json = Formatter.format(raw, %{}) |> IO.iodata_to_binary()
      assert Jason.decode!(json)["event"] == "external_log"
      assert String.ends_with?(json, "\n")
      assert length(String.split(json, "\n", trim: true)) == 1
      refute json =~ @canary
    end

    assert Custyard.Log.filter(%{}, nil).msg == {:string, "log_event_rejected"}

    spoofed = %{
      level: :error,
      msg: {:string, @canary},
      meta: %{custyard_event: :not_a_registered_event}
    }

    assert Custyard.Log.filter(spoofed, nil).msg == {:string, "external_log"}
  end

  test "the real logger boundary protects every handler and JSON keeps diagnostics" do
    assert List.keymember?(:logger.get_primary_config()[:filters], :custyard_log_privacy, 0)
    handler = :custyard_policy_test_handler

    assert :ok =
             :logger.add_handler(handler, Custyard.LogTest.Handler, %{
               level: :debug,
               config: %{owner: self()}
             })

    on_exit(fn -> :logger.remove_handler(handler) end)
    id = Custyard.Log.new_id()
    Logger.metadata(request_id: id, email: @canary)

    capture_log(fn ->
      Log.warning(
        :logging_self_test,
        [operator_id: 12, message_id: 34, tenant_id: 56] ++
          Log.failure({422, %{"code" => "validation_failed", "errors" => %{"from" => [@canary]}}})
      )

      Logger.error(@canary, raw_payload: @canary)
      assert List.keymember?(:logger.get_primary_config()[:filters], :custyard_log_privacy, 0)
    end)

    assert_receive {:policy_log, safe, json}
    assert safe.msg == {:string, "logging_self_test"}
    record = Jason.decode!(json)
    assert record["event"] == "logging_self_test"
    assert record["request_id"] == id
    assert record["provider_status"] == 422
    assert record["provider_code"] == "validation_failed"
    assert record["validation_fields"] == ["from"]
    assert record["message_id"] == 34
    assert record["tenant_id"] == 56
    assert record["service"] == "custyard"
    assert record["schema_version"] == 1
    assert {:ok, _, _} = DateTime.from_iso8601(record["timestamp"])
    refute json =~ @canary
    assert_receive {:policy_log, external, external_json}
    assert external.msg == {:string, "external_log"}
    refute inspect(external) =~ @canary
    refute external_json =~ @canary
    assert {:ok, %{formatter: {Formatter, _}}} = :logger.get_handler_config(:default)
  end

  test "Sentry SDK logs retain their fixed loop-prevention domain" do
    event = %{
      level: :error,
      msg: {:string, @canary},
      meta: %{domain: [:sentry, :private_user_domain]}
    }

    filtered = Custyard.Log.filter(event, nil)
    assert filtered.meta.domain == [:sentry]
    refute inspect(filtered) =~ @canary
    refute inspect(filtered) =~ "private_user_domain"
  end

  test "malformed Sentry diagnostics preserve loop prevention on the failure path" do
    safe = Custyard.Log.filter(%{level: :invalid, meta: %{domain: [:sentry, @canary]}}, nil)
    assert safe.msg == {:string, "log_event_rejected"}
    assert safe.meta.domain == [:sentry]
    refute inspect(safe) =~ @canary
  end

  test "OTP diagnostics retain the actual code origin without argument/state contents" do
    Code.ensure_loaded!(CustyardWeb.Operator.SessionController)

    raw = %{
      level: :error,
      msg:
        {:report,
         %{
           reason:
             {%RuntimeError{message: @canary},
              [{CustyardWeb.Operator.SessionController, :create, [@canary, @canary], [line: 30]}]},
           state: @canary
         }},
      meta: %{mfa: {:gen_server, :error_info, 7}},
      unexpected_compartment: @canary
    }

    safe = Custyard.Log.filter(raw, nil)
    assert Enum.sort(Map.keys(safe)) == [:level, :meta, :msg]
    refute inspect(safe) =~ @canary
    assert safe.meta.error_type == "Elixir.RuntimeError"
    assert safe.meta.origin == "Elixir.CustyardWeb.Operator.SessionController.create/2"
    assert Custyard.Log.filter(safe, nil) == safe
    record = Formatter.format(safe, %{}) |> IO.iodata_to_binary() |> Jason.decode!()
    assert record["origin"] == "Elixir.CustyardWeb.Operator.SessionController.create/2"
    assert record["code_location"] == record["origin"]
    refute inspect(record) =~ @canary

    proc = %{
      raw
      | msg:
          {:report,
           [
             error_info:
               {:error, {:badkey, @canary},
                [{CustyardWeb.Operator.SessionController, :create, 2, []}]}
           ]}
    }

    assert Custyard.Log.filter(proc, nil).meta.error_type == "Elixir.KeyError"
    assert Custyard.Log.filter(proc, nil).meta.origin == record["origin"]

    {:report, own_report} = proc.msg

    wrapped = %{
      proc
      | msg: {:report, %{label: {:proc_lib, :crash}, report: [own_report, [@canary]]}}
    }

    safe_wrapped = Custyard.Log.filter(wrapped, nil)
    assert safe_wrapped.meta.error_type == "Elixir.KeyError"
    assert safe_wrapped.meta.origin == record["origin"]
    assert Custyard.Log.filter(safe_wrapped, nil) == safe_wrapped
    refute inspect(safe_wrapped) =~ @canary
  end

  test "task and operation context survives concurrency and restores worker state" do
    id = Custyard.Log.new_id()
    parent_operation = Custyard.Log.new_id()
    Logger.metadata(request_id: id, operation_id: parent_operation, email: @canary)
    parent = self()

    callback =
      Custyard.Log.task(
        fn ->
          send(parent, {:child_context, Custyard.Log.context(), Logger.metadata()})
        end,
        tenant_id: 44
      )

    task = Task.async(callback)
    assert {:child_context, _, _} = Task.await(task)
    assert_receive {:child_context, context, metadata}
    assert context.request_id == id
    assert context.tenant_id == 44
    assert context.parent_operation_id == parent_operation
    refute context.operation_id == parent_operation
    refute Keyword.has_key?(metadata, :email)
    assert Custyard.Log.context().operation_id == parent_operation

    assert_raise RuntimeError, fn ->
      Custyard.Log.operation([message_id: 123], fn -> raise "worker failure" end)
    end

    assert Custyard.Log.context().operation_id == parent_operation
    refute Map.has_key?(Custyard.Log.context(), :message_id)
  end

  test "debug logging cannot expose SQL parameters or Phoenix request payloads" do
    assert Application.fetch_env!(:custyard, Custyard.Repo)[:log] == false

    assert Application.fetch_env!(:custyard, Custyard.Repo)[
             :show_sensitive_data_on_connection_error
           ] == false

    assert Application.fetch_env!(:phoenix, :filter_parameters) == {:keep, []}
  end

  test "audit operation types cannot disappear from diagnostics when new events are added" do
    for event_type <- Custyard.AuditEvent.event_types() do
      assert Custyard.Log.sanitize_metadata(event_type: event_type) == %{
               event_type: Atom.to_string(event_type)
             }
    end
  end

  test "domain failure and purpose catalogs survive the logging schema" do
    for purpose <- Custyard.InboundRouteWebhook.purposes() do
      assert Custyard.Log.sanitize_metadata(purpose: purpose) == %{purpose: to_string(purpose)}
    end

    categories = Consumer.failure_categories()

    for category <- categories do
      reason = String.to_existing_atom(category)

      for failure <- [reason, {reason, @canary}] do
        fields = Custyard.Log.failure(failure)
        assert fields[:reason] == reason
        assert Custyard.Log.sanitize_metadata(fields)[:reason] == category
        refute inspect(fields) =~ @canary
      end
    end

    for reason <-
          ~w(attachment_fetch_failed attachment_processing_failed channel_route_mismatch concurrent_update invalid_enabled_value)a do
      assert Custyard.Log.failure(reason) == [reason: reason]
      assert Custyard.Log.sanitize_metadata(reason: reason) == %{reason: Atom.to_string(reason)}
    end
  end

  test "logged changeset fields remain diagnostic without retaining values" do
    for schema <- [
          Custyard.Message,
          Custyard.Conversation,
          Custyard.InboundChannel,
          Custyard.InboundRoute,
          Custyard.OperatorAccount,
          Custyard.AuditEvent
        ],
        field <- schema.__schema__(:fields) ++ schema.__schema__(:virtual_fields) do
      fields = Custyard.Log.failure(%Ecto.Changeset{errors: [{field, {@canary, []}}]})
      assert fields[:validation_fields] == [Atom.to_string(field)]
      refute inspect(fields) =~ @canary
    end
  end

  test "literal operational metadata uses declared fields and accepted values" do
    root = Path.expand("../..", __DIR__)

    sources =
      Enum.flat_map(["lib/**/*.ex", "priv/repo/migrations/*.exs"], fn pattern ->
        Path.wildcard(Path.join(root, pattern))
      end)

    violations =
      Enum.flat_map(sources, fn path ->
        {_, failures} =
          Macro.prewalk(Code.string_to_quoted!(File.read!(path)), [], fn
            {{:., location, [{:__aliases__, _, name}, level]}, _, [_event, metadata]} = node, acc
            when name in [[:Log], [:Custyard, :Log]] and
                   level in [
                     :debug,
                     :info,
                     :notice,
                     :warning,
                     :error,
                     :critical,
                     :alert,
                     :emergency
                   ] ->
              failures =
                for {key, value} <- literal_metadata(metadata),
                    not declared_literal_metadata?(key, value),
                    do: {path, location[:line], key}

              {node, failures ++ acc}

            {{:., location, [{:__aliases__, _, [:Sentry]}, :capture_message]}, _, [name | _]} =
                node,
            acc ->
              if Custyard.Log.safe_event_name(name),
                do: {node, acc},
                else: {node, [{path, location[:line], :unregistered_sentry_event} | acc]}

            node, acc ->
              {node, acc}
          end)

        failures
      end)

    assert violations == []
  end

  test "application code cannot bypass the structured event API" do
    root = Path.expand("../..", __DIR__)

    sources =
      Enum.flat_map(["lib/**/*.ex", "priv/repo/migrations/*.exs"], fn pattern ->
        Path.wildcard(Path.join(root, pattern))
      end)

    assert Path.join(root, "lib/custyard/application.ex") in sources
    assert Enum.any?(sources, &String.contains?(&1, "/priv/repo/migrations/"))

    violations =
      for path <- sources,
          not String.ends_with?(path, "/custyard/log.ex"),
          ast = Code.string_to_quoted!(File.read!(path)),
          cli_output? =
            Path.relative_to(path, root) in [
              "lib/custyard/release.ex",
              "lib/custyard/release/dsar.ex",
              "lib/custyard/release/acknowledgments.ex"
            ],
          {_, bad} =
            Macro.prewalk(ast, [], fn
              {{:., location, [{:__aliases__, _, [:Logger]}, function]}, _, _} = node, acc
              when function in [
                     :debug,
                     :info,
                     :notice,
                     :warning,
                     :error,
                     :critical,
                     :alert,
                     :emergency,
                     :log,
                     :bare_log
                   ] ->
                {node, [{path, location[:line]} | acc]}

              {{:., location, [:logger, function]}, _, _} = node, acc
              when function in [
                     :debug,
                     :info,
                     :notice,
                     :warning,
                     :error,
                     :critical,
                     :alert,
                     :emergency,
                     :log
                   ] ->
                {node, [{path, location[:line]} | acc]}

              {directive, location, [{:__aliases__, _, [:Logger]} | _]} = node, acc
              when directive in [:alias, :import] ->
                {node, [{path, location[:line]} | acc]}

              {:import, location, [:logger | _]} = node, acc ->
                {node, [{path, location[:line]} | acc]}

              {{:., location, [{:__aliases__, _, [:IO]}, function]}, _, _} = node, acc
              when function in [:puts, :write, :warn, :inspect] ->
                if cli_output?, do: {node, acc}, else: {node, [{path, location[:line]} | acc]}

              {{:., location, [:io, function]}, _, _} = node, acc
              when function in [:format, :fwrite, :put_chars] ->
                if cli_output?, do: {node, acc}, else: {node, [{path, location[:line]} | acc]}

              {{:., location, [:erlang, function]}, _, _} = node, acc
              when function in [:display, :display_string] ->
                {node, [{path, location[:line]} | acc]}

              {:dbg, location, _} = node, acc ->
                {node, [{path, location[:line]} | acc]}

              node, acc ->
                {node, acc}
            end),
          item <- bad,
          do: item

    assert violations == []
  end

  defp literal_metadata(fields) when is_list(fields) do
    if Keyword.keyword?(fields), do: fields, else: []
  end

  defp literal_metadata({:%{}, _, fields}), do: fields

  defp literal_metadata({:++, _, [left, right]}),
    do: literal_metadata(left) ++ literal_metadata(right)

  defp literal_metadata(_fields), do: []

  defp declared_literal_metadata?(key, value) do
    declared? = key in Custyard.Log.metadata_keys()
    literal? = is_atom(value) or is_binary(value) or is_number(value)

    declared? and
      (is_nil(value) or not literal? or
         map_size(Custyard.Log.sanitize_metadata(%{key => value})) == 1)
  end
end
