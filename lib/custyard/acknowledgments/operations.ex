defmodule Custyard.Acknowledgments.Operations do
  @moduledoc """
  Broker recovery operations for the operator UI, release commands and Mix.

  Each operation opens its own connection and closes it when the operation
  ends, including when the calling process is killed. Results carry fixed
  error atoms and sanitized fields only; `inspect_failure/0` alone returns
  original evidence, for authorized terminals.
  """
  alias Custyard.Acknowledgments.{Audit, Broker, Config, Consumer, Evidence, Topology}

  @doc "Declares the work, retry and failure queues. Needs the provisioning credential."
  def provision,
    do: with_channel(fn channel, _connection, config -> Topology.provision(channel, config) end)

  @doc """
  Ready and consumer counts per queue, work queue first:
  `{:ok, [%{queue: name, role: role, ready: n, consumers: n} | %{queue: name, role: role, error: atom}]}`
  where role is `:work`, `{:retry, attempt}` or `:failed`.
  """
  def status do
    with_channel(fn _channel, connection, config ->
      {:ok,
       Enum.map(queues(config), fn {role, queue} ->
         Map.merge(%{queue: queue, role: role}, counts(connection, queue))
       end)}
    end)
  end

  @doc "Queue roles and names for a configuration, in processing order."
  def queues(config) do
    retries =
      config[:retry_delays]
      |> Enum.with_index(1)
      |> Enum.map(fn {_, attempt} -> {{:retry, attempt}, Topology.retry(config, attempt)} end)

    [{:work, config[:queue]}] ++ retries ++ [{:failed, Topology.failure(config)}]
  end

  @doc """
  Sanitized fields of the oldest failed message: `{:ok, summary}`, `:empty` or
  `{:error, reason}`. The body and headers never leave this process. The
  message goes back to its position when the operation's channel closes; an
  explicit requeue would move a quorum queue message to the back.
  """
  def failure_summary do
    with_channel(fn channel, _connection, config ->
      case fetch_failure(channel, config) do
        {:ok, body, meta} -> {:ok, summarize(body, meta)}
        other -> other
      end
    end)
  end

  @doc """
  The oldest failed message with its original body, for authorized terminals:
  `{:ok, %{body: body, summary: summary}}`, `:empty` or `{:error, reason}`.
  The message stays in place.
  """
  def inspect_failure do
    with_channel(fn channel, _connection, config ->
      case fetch_failure(channel, config) do
        {:ok, body, meta} -> {:ok, %{body: body, summary: summarize(body, meta)}}
        other -> other
      end
    end)
  end

  @doc """
  Replays the oldest failed message to the work queue, auditing it in this
  process. This is the only replay entry point, so no replay goes unaudited.

  Before publishing, an `:acknowledgment_replayed` row with outcome
  `"started"` must be written; if it cannot be, nothing is published, the
  message stays in place and the result is `{:error, :audit_failed}`. A
  second row then records the outcome, whatever it is (a failure to write
  that one is logged, and the started row remains as evidence).

  `expected` guards the replay: `nil` replays whatever is oldest (release and
  Mix commands); a submission ID replays only while the oldest message has it;
  `%{submission_id: id, body_sha256: hash}` (the operator page's inspected
  summary) also requires the identical body, since two retained failures can
  share a submission ID with different evidence. Otherwise the message stays
  in place and the result is `{:error, :changed}`. `actor` is an operator
  account or `"cli"`, `"mix"` or `"console"`.
  """
  def replay(expected, actor) do
    if !Audit.actor?(actor), do: raise(ArgumentError, "unknown audit actor")

    {result, summary} =
      case with_channel(&replay_message(&1, &2, &3, expected, actor)) do
        {:replay, result, summary} -> {result, summary}
        other -> {other, %{}}
      end

    Audit.record(:acknowledgment_replayed, actor, nil, replay_payload(summary, result))

    result
  end

  defp replay_payload(summary, result) do
    %{
      "source" => summary[:source],
      "submission_id" => summary[:submission_id],
      "body_sha256" => summary[:body_sha256],
      "category" => summary[:category],
      "attempt" => summary[:attempt],
      "outcome" => replay_outcome(result)
    }
  end

  defp replay_outcome(:started), do: "started"
  defp replay_outcome(:ok), do: "replayed"
  defp replay_outcome(:empty), do: "empty"
  defp replay_outcome({:error, {:unroutable, _}}), do: "unroutable"
  defp replay_outcome({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp replay_outcome(_), do: "operation_failed"

  defp expected?(nil, _summary), do: true

  defp expected?(submission_id, summary) when is_binary(submission_id),
    do: summary.readable and summary.submission_id == submission_id

  defp expected?(%{submission_id: id, body_sha256: hash}, summary),
    do: expected?(id, summary) and summary.body_sha256 == hash

  defp replay_message(channel, connection, config, expected, actor) do
    case fetch_failure(channel, config) do
      {:ok, body, meta} ->
        summary = summarize(body, meta)

        cond do
          not expected?(expected, summary) ->
            {:replay, {:error, :changed}, summary}

          # The attempt is on record before the message moves, or it does not move.
          Audit.record(:acknowledgment_replayed, actor, nil, replay_payload(summary, :started)) ==
              :error ->
            {:replay, {:error, :audit_failed}, summary}

          true ->
            result =
              with :ok <-
                     Broker.publish(
                       connection,
                       config[:queue],
                       body,
                       [],
                       config[:confirm_timeout]
                     ),
                   do: AMQP.Basic.ack(channel, meta.delivery_tag)

            {:replay, result, summary}
        end

      other ->
        {:replay, other, %{}}
    end
  end

  @messages %{
    invalid_config: "Acknowledgment configuration is missing or invalid",
    invalid_url: "The broker URL is not a valid AMQP URI",
    unreachable: "The broker is unreachable",
    timeout: "The broker did not respond in time",
    auth_failed: "The broker refused the credentials",
    access_refused: "The broker credential lacks permission for this operation",
    tls_failed: "The TLS connection to the broker failed",
    connection_failed: "The broker connection failed",
    channel_failed: "The broker channel could not be opened",
    queue_missing: "A queue is missing; provision the topology",
    precondition_failed: "An existing queue has incompatible properties",
    operation_failed: "The broker operation failed; messages remain recoverable",
    changed: "The oldest failed message changed; inspect again",
    audit_failed: "The replay could not be audited, so nothing was replayed",
    unroutable: "The work queue is missing; provision the topology",
    publication_failed: "The replay was not confirmed; the message is still retained",
    publication_rejected: "The broker rejected the replay; the message is still retained",
    publication_unconfirmed: "The replay was not confirmed; the message is still retained"
  }

  @doc "A fixed message for an operation error; anything unexpected gets a generic one."
  def error_message({:error, reason}), do: error_message(reason)
  def error_message({:unroutable, _}), do: @messages.unroutable
  def error_message(reason) when is_map_key(@messages, reason), do: Map.fetch!(@messages, reason)
  def error_message(_), do: @messages.operation_failed

  @doc false
  # Public for the caller-death integration test.
  def with_channel(operation) do
    case validated_config() do
      {:ok, config} -> guarded(config, operation)
      :error -> {:error, :invalid_config}
    end
  end

  defp validated_config do
    {:ok, Config.load() |> Config.validate!()}
  rescue
    ArgumentError -> :error
  end

  defp guarded(config, operation) do
    caller = self()
    {guard, monitor} = spawn_monitor(fn -> guard(caller, config) end)

    receive do
      {^guard, {:ok, connection, channel}} ->
        try do
          operation.(channel, connection, config)
        after
          close_connection(connection)
          send(guard, :done)
          Process.demonitor(monitor, [:flush])
        end

      {^guard, {:error, _} = error} ->
        Process.demonitor(monitor, [:flush])
        error

      {:DOWN, ^monitor, :process, ^guard, _} ->
        {:error, :connection_failed}
    end
  catch
    :exit, reason -> {:error, exit_error(reason)}
  end

  # Opens the connection for the caller and closes it if the caller dies by any
  # means. AMQP connections are not linked to their opener, so the `after` in a
  # killed LiveView task never runs; without this a fetched message would stay
  # unacknowledged on a leaked channel until the application restarts.
  defp guard(caller, config) do
    caller_monitor = Process.monitor(caller)

    case Broker.open(config) do
      {:ok, connection, channel} ->
        send(caller, {self(), {:ok, connection, channel}})

        receive do
          :done -> :ok
          {:DOWN, ^caller_monitor, :process, _, _} -> close_connection(connection)
        end

      error ->
        send(caller, {self(), error})
    end
  end

  defp fetch_failure(channel, config) do
    case AMQP.Basic.get(channel, Topology.failure(config), no_ack: false) do
      {:ok, body, meta} -> {:ok, body, meta}
      {:empty, _} -> :empty
      _ -> {:error, :operation_failed}
    end
  end

  # A failed passive declare closes its channel, so each queue gets its own.
  defp counts(connection, queue) do
    case AMQP.Channel.open(connection) do
      {:ok, channel} ->
        try do
          case AMQP.Queue.declare(channel, queue, passive: true) do
            {:ok, %{message_count: ready, consumer_count: consumers}} ->
              %{ready: ready, consumers: consumers}

            _ ->
              %{error: :operation_failed}
          end
        catch
          :exit, reason -> %{error: exit_error(reason)}
        after
          close_channel(channel)
        end

      _ ->
        %{error: :channel_failed}
    end
  end

  defp summarize(body, meta) do
    headers = if is_list(meta[:headers]), do: meta[:headers], else: []

    # The digest identifies the exact body for a guarded replay without the
    # body itself leaving this process.
    body
    |> identity()
    |> Map.merge(%{
      category: category(headers),
      attempt: attempt(headers),
      body_sha256: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    })
  end

  # Source and submission ID are shown only from a body the consumer could
  # have read; anything else is reported as unreadable.
  defp identity(body) do
    with true <- byte_size(body) <= Evidence.max_message_bytes(),
         {:ok, %{"source" => source, "submission_id" => id}} <- Jason.decode(body),
         true <- Evidence.valid_identity?(source) and Evidence.valid_identity?(id) do
      %{readable: true, source: source, submission_id: id}
    else
      _ -> %{readable: false, source: nil, submission_id: nil}
    end
  end

  defp category(headers) do
    case List.keyfind(headers, "custyard-failure", 0) do
      {_, :longstr, value} -> if value in Consumer.failure_categories(), do: value
      _ -> nil
    end
  end

  defp attempt(headers) do
    case List.keyfind(headers, "custyard-attempt", 0) do
      {_, _, value} when is_integer(value) and value >= 0 -> value
      _ -> nil
    end
  end

  defp exit_error({{:shutdown, {:server_initiated_close, code, _}}, _}), do: close_error(code)
  defp exit_error({:shutdown, {:server_initiated_close, code, _}}), do: close_error(code)
  defp exit_error(_), do: :operation_failed

  defp close_error(404), do: :queue_missing
  defp close_error(403), do: :access_refused
  defp close_error(406), do: :precondition_failed
  defp close_error(_), do: :operation_failed

  defp close_channel(channel) do
    AMQP.Channel.close(channel)
  catch
    :exit, _ -> :ok
  end

  defp close_connection(connection) do
    AMQP.Connection.close(connection)
  catch
    :exit, _ -> :ok
  end
end
