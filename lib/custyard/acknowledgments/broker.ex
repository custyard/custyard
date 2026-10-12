defmodule Custyard.Acknowledgments.Broker do
  @moduledoc "Mandatory, persistent publication with correlated publisher confirms."
  def open(config) do
    with {:ok, connection} <- AMQP.Connection.open(config[:url]) do
      case AMQP.Channel.open(connection) do
        {:ok, channel} ->
          {:ok, connection, channel}

        error ->
          AMQP.Connection.close(connection)
          error
      end
    end
  rescue
    _ -> {:error, :broker_connection_failed}
  catch
    :exit, _ -> {:error, :broker_connection_failed}
  end

  # One fresh channel per transfer prevents stale returns/confirms being mistaken
  # for this publication. RabbitMQ sends basic.return before its confirm.
  def publish(connection, queue, body, headers, timeout) do
    caller = self()
    token = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        result = publish_isolated(connection, queue, body, headers, timeout)
        send(caller, {token, result})
      end)

    receive do
      {^token, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _} ->
        {:error, :publication_failed}
    after
      timeout + 1_000 ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])
        {:error, :publication_unconfirmed}
    end
  end

  defp publish_isolated(connection, queue, body, headers, timeout) do
    with {:ok, channel} <- AMQP.Channel.open(connection) do
      try do
        with :ok <- AMQP.Confirm.select(channel),
             :ok <- AMQP.Confirm.register_handler(channel, self()),
             :ok <- AMQP.Basic.return(channel, self()),
             :ok <-
               AMQP.Basic.publish(channel, "", queue, body,
                 persistent: true,
                 mandatory: true,
                 content_type: "application/json",
                 headers: headers
               ) do
          await_confirmation(timeout)
        end
      after
        AMQP.Channel.close(channel)
      end
    end
  end

  defp await_confirmation(timeout) do
    receive do
      {:basic_return, _body, metadata} -> {:error, {:unroutable, metadata.reply_code}}
      {:basic_ack, 1, _} -> :ok
      {:basic_nack, 1, _} -> {:error, :publication_rejected}
    after
      timeout -> {:error, :publication_unconfirmed}
    end
  end
end
