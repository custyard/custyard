defmodule Custyard.Acknowledgments.Operations do
  @moduledoc "Broker recovery operations usable from Mix or release RPC. Inspection exposes evidence explicitly."
  alias Custyard.Acknowledgments.{Broker, Config, Topology}

  def provision,
    do: with_channel(fn channel, _connection, config -> Topology.provision(channel, config) end)

  def status do
    with_channel(fn channel, _connection, config ->
      queues =
        [config[:queue], Topology.failure(config)] ++
          Enum.map(Enum.with_index(config[:retry_delays], 1), fn {_, index} ->
            Topology.retry(config, index)
          end)

      Enum.reduce_while(queues, {:ok, []}, fn queue, {:ok, results} ->
        case AMQP.Queue.declare(channel, queue, passive: true) do
          {:ok, counts} -> {:cont, {:ok, [{queue, counts} | results]}}
          error -> {:halt, error}
        end
      end)
    end)
  end

  def inspect_failure do
    with_channel(fn channel, _connection, config ->
      case AMQP.Basic.get(channel, Topology.failure(config), no_ack: false) do
        {:ok, body, meta} ->
          with :ok <- AMQP.Basic.reject(channel, meta.delivery_tag, requeue: true),
               do: {:ok, %{body: body, headers: meta[:headers]}}

        {:empty, _} ->
          :empty

        error ->
          error
      end
    end)
  end

  def replay do
    with_channel(fn channel, connection, config ->
      case AMQP.Basic.get(channel, Topology.failure(config), no_ack: false) do
        {:ok, body, meta} ->
          with :ok <-
                 Broker.publish(connection, config[:queue], body, [], config[:confirm_timeout]),
               do: AMQP.Basic.ack(channel, meta.delivery_tag)

        {:empty, _} ->
          :empty

        error ->
          error
      end
    end)
  end

  defp with_channel(operation) do
    config = Config.load() |> Config.validate!()

    with {:ok, connection, channel} <- Broker.open(config) do
      try do
        operation.(channel, connection, config)
      after
        AMQP.Connection.close(connection)
      end
    end
  catch
    :exit, _ -> {:error, :broker_operation_failed}
  end
end
