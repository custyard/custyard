defmodule Custyard.Acknowledgments.Broker do
  @moduledoc "Mandatory, persistent publication with correlated publisher confirms."
  alias Custyard.Acknowledgments.Config

  # Bounds the TCP connect and TLS handshake; amqp_client's default is a minute.
  @connection_timeout 5_000

  @doc """
  Opens a connection and channel. Every failure is a fixed atom: amqp_client
  errors can embed the URI with its password, so none is passed through.
  """
  def open(config) do
    with {:ok, _} <- Config.network_params(config[:url]),
         {:ok, connection} <-
           AMQP.Connection.open(config[:url], connection_timeout: @connection_timeout) do
      case AMQP.Channel.open(connection) do
        {:ok, channel} ->
          {:ok, connection, channel}

        _ ->
          close_quietly(connection)
          {:error, :channel_failed}
      end
    else
      :error -> {:error, :invalid_url}
      {:error, reason} -> {:error, connection_error(reason)}
      _ -> {:error, :connection_failed}
    end
  rescue
    _ -> {:error, :connection_failed}
  catch
    :exit, _ -> {:error, :connection_failed}
  end

  @unreachable ~w(econnrefused ehostunreach enetunreach nxdomain unknown_host closed econnreset eafnosupport)a
  @timeouts ~w(timeout etimedout handshake_receive_timed_out)a

  defp connection_error(reason) when reason in @unreachable, do: :unreachable
  defp connection_error(reason) when reason in @timeouts, do: :timeout
  defp connection_error({:auth_failure, _}), do: :auth_failed
  defp connection_error(:auth_failure), do: :auth_failed
  # Refused access to the vhost after a successful login.
  defp connection_error(reason) when reason in [:not_allowed, :access_refused],
    do: :access_refused

  defp connection_error({:tls_alert, _}), do: :tls_failed
  defp connection_error({:options, _}), do: :tls_failed
  defp connection_error(_), do: :connection_failed

  defp close_quietly(connection) do
    AMQP.Connection.close(connection)
  catch
    :exit, _ -> :ok
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
