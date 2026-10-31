defmodule Custyard.Acknowledgments.Consumer do
  @moduledoc "Single bounded consumer: commit first, acknowledge second; transfers confirm first."
  use GenServer
  require Custyard.Log, as: Log
  alias Custyard.Acknowledgments.{Broker, Config, Evidence, Topology}

  # Failure headers, and so the operator UI, only ever carry one of these.
  @failure_categories ~w(message_too_large storage_unavailable source_mismatch invalid_json unmapped_organization invalid_evidence conflicting_submission processing_error)

  # Published state, so status reads never wait behind message processing.
  # Replacing an atom value needs no global garbage collection.
  @status_key {__MODULE__, :status}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Every category a failure header can carry."
  def failure_categories, do: @failure_categories

  @doc """
  `:connected` while this node's consumer holds a subscribed channel, otherwise
  `:connecting`, including while the consumer is not running.
  """
  def status do
    if Process.whereis(__MODULE__),
      do: :persistent_term.get(@status_key, :connecting),
      else: :connecting
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    publish_status(:connecting)
    config = Keyword.get(opts, :config, Config.load()) |> Config.validate!()
    send(self(), :connect)
    {:ok, %{config: config, connection: nil, channel: nil, monitors: [], consumer_tag: nil}}
  end

  # Crash reports and :sys.get_status/1 render the state; the URL carries the
  # broker password.
  @impl true
  def format_status(status) do
    Map.new(status, fn
      {:state, %{config: config} = state} when is_list(config) ->
        {:state, %{state | config: Keyword.replace(config, :url, "[REDACTED]")}}

      other ->
        other
    end)
  end

  # Without a catch-all, an unexpected call would crash the consumer and put
  # its state in the crash report.
  @impl true
  def handle_call(_request, _from, state), do: {:reply, {:error, :unsupported}, state}

  @impl true
  def handle_info(:connect, %{connection: connection} = state) when not is_nil(connection),
    do: {:noreply, state}

  def handle_info(:connect, state) do
    case Broker.open(state.config) do
      {:ok, connection, channel} ->
        monitors = [Process.monitor(connection.pid), Process.monitor(channel.pid)]
        state = %{state | connection: connection, channel: channel, monitors: monitors}

        case subscribe(channel, state.config) do
          {:ok, tag} ->
            publish_status(:connected)
            {:noreply, %{state | connection: connection, channel: channel, consumer_tag: tag}}

          _ ->
            reconnect(state)
        end

      {:error, _} ->
        reconnect(state)
    end
  end

  def handle_info({:basic_deliver, _, _}, %{channel: nil} = state), do: {:noreply, state}

  def handle_info(
        {:basic_deliver, body, %{consumer_tag: tag} = meta},
        %{consumer_tag: tag} = state
      ) do
    Log.operation([], fn ->
      case process(body, state.config[:source]) do
        {:ok, record} ->
          Log.info(:acknowledgment_committed,
            acknowledgment_id: record.id,
            submission_ref:
              Log.reference(:erlang.term_to_binary({record.source, record.submission_id}))
          )

          case ack(state.channel, meta.delivery_tag) do
            :ok -> {:noreply, state}
            _ -> reconnect(state)
          end

        {:error, reason} ->
          attempt = attempts(meta[:headers]) + 1

          queue =
            if attempt <= length(state.config[:retry_delays]),
              do: Topology.retry(state.config, attempt),
              else: Topology.failure(state.config)

          headers = [
            {"custyard-attempt", :long, attempt},
            {"custyard-failure", :longstr, failure_reason(reason)}
          ]

          Log.warning(
            :acknowledgment_processing_failed,
            trace(body, state.config[:source]) ++ Log.failure(reason)
          )

          with :ok <-
                 Broker.publish(
                   state.connection,
                   queue,
                   body,
                   headers,
                   state.config[:confirm_timeout]
                 ),
               :ok <- ack(state.channel, meta.delivery_tag) do
            {:noreply, state}
          else
            _ -> reconnect(state)
          end
      end
    end)
  end

  def handle_info({:basic_deliver, _, _}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _, _}, state) do
    if ref in state.monitors, do: reconnect(state), else: {:noreply, state}
  end

  def handle_info({:basic_cancel, %{consumer_tag: tag}}, %{consumer_tag: tag} = state),
    do: reconnect(state)

  def handle_info({:basic_cancel, _}, state), do: {:noreply, state}
  def handle_info({:basic_consume_ok, _}, state), do: {:noreply, state}
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, %{connection: nil}), do: publish_status(:connecting)

  def terminate(_, state) do
    publish_status(:connecting)
    close_subscription(state)
  end

  def process(body, source, ingest \\ &Custyard.Acknowledgments.ingest/1) do
    if byte_size(body) > Evidence.max_message_bytes(),
      do: {:error, :message_too_large},
      else: decode_and_ingest(body, source, ingest)
  rescue
    _ -> {:error, :storage_unavailable}
  catch
    :exit, _ -> {:error, :storage_unavailable}
  end

  defp decode_and_ingest(body, source, ingest) do
    with {:ok, event} when is_map(event) <- Jason.decode(body),
         true <- event["source"] == source do
      ingest.(event)
    else
      false -> {:error, :source_mismatch}
      _ -> {:error, :invalid_json}
    end
  end

  # A message published without headers (OTS's first delivery) carries
  # `:undefined`; List.keyfind/3 raising on it would crash the consumer on every
  # redelivery of a failing message.
  def attempts(headers) when is_list(headers) do
    case List.keyfind(headers, "custyard-attempt", 0) do
      {_, _, value} when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  def attempts(_), do: 0

  defp trace(body, source) do
    with true <- byte_size(body) <= Evidence.max_message_bytes(),
         {:ok, event} when is_map(event) <- Jason.decode(body),
         id when is_binary(id) <- event["submission_id"],
         true <- Evidence.valid_identity?(id) do
      [submission_ref: Log.reference(:erlang.term_to_binary({source, id}))]
    else
      _ -> []
    end
  end

  @doc false
  def failure_reason({reason, _}) when is_atom(reason), do: failure_reason(reason)

  def failure_reason(reason) when is_atom(reason) do
    category = Atom.to_string(reason)
    if category in @failure_categories, do: category, else: "processing_error"
  end

  def failure_reason(_), do: "processing_error"

  defp publish_status(status), do: :persistent_term.put(@status_key, status)

  defp reconnect(state) do
    Log.warning(:acknowledgment_broker_unavailable, reason: :retry_scheduled)
    publish_status(:connecting)
    Enum.each(state.monitors, &Process.demonitor(&1, [:flush]))
    close_subscription(state)
    Process.send_after(self(), :connect, state.config[:reconnect_delay])
    {:noreply, %{state | connection: nil, channel: nil, monitors: [], consumer_tag: nil}}
  end

  defp ack(channel, tag) do
    AMQP.Basic.ack(channel, tag)
  catch
    :exit, _ -> {:error, :ack_failed}
  end

  defp subscribe(channel, config) do
    with :ok <- AMQP.Basic.qos(channel, prefetch_count: config[:prefetch]) do
      AMQP.Basic.consume(channel, config[:queue], self(), no_ack: false)
    end
  catch
    :exit, _ -> {:error, :subscription_failed}
  end

  defp close_subscription(state) do
    if state.channel do
      if state.consumer_tag, do: AMQP.Basic.cancel(state.channel, state.consumer_tag)
      AMQP.Channel.close(state.channel)
    end

    close_connection(state.connection)
  catch
    :exit, _ -> close_connection(state.connection)
  end

  defp close_connection(nil), do: :ok

  defp close_connection(connection) do
    AMQP.Connection.close(connection)
  catch
    :exit, _ -> :ok
  end
end
