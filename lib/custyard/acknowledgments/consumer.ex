defmodule Custyard.Acknowledgments.Consumer do
  @moduledoc "Single bounded consumer: commit first, acknowledge second; transfers confirm first."
  use GenServer
  require Logger
  alias Custyard.Acknowledgments.{Broker, Config, Evidence, Topology}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    config = Keyword.get(opts, :config, Config.load()) |> Config.validate!()
    send(self(), :connect)
    {:ok, %{config: config, connection: nil, channel: nil, monitors: [], consumer_tag: nil}}
  end

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
    case process(body, state.config[:source]) do
      {:ok, record} ->
        Logger.info("Acknowledgment committed",
          source: record.source,
          submission_id: record.submission_id
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

        Logger.warning(
          "Acknowledgment processing failed; transferring to #{queue}: #{failure_reason(reason)}",
          trace(body, state.config[:source])
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
  def terminate(_, %{connection: nil}), do: :ok
  def terminate(_, state), do: close_subscription(state)

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

  def attempts(headers) do
    case List.keyfind(headers || [], "custyard-attempt", 0) do
      {_, _, value} when is_integer(value) and value >= 0 -> value
      _ -> 0
    end
  end

  defp trace(body, source) do
    with true <- byte_size(body) <= Evidence.max_message_bytes(),
         {:ok, event} when is_map(event) <- Jason.decode(body),
         id when is_binary(id) <- event["submission_id"],
         true <- Evidence.valid_identity?(id) do
      [source: source, submission_id: id]
    else
      _ -> [source: source]
    end
  end

  defp failure_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason({reason, _}) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_reason(_), do: "processing_error"

  defp reconnect(state) do
    Logger.warning("Acknowledgment broker unavailable; connection retry scheduled")
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
