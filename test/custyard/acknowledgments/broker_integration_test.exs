defmodule Custyard.Acknowledgments.BrokerIntegrationTest do
  use ExUnit.Case, async: false
  alias Custyard.Acknowledgments.{Broker, Topology}
  @moduletag :rabbitmq
  @moduletag skip: is_nil(System.get_env("ACKNOWLEDGMENTS_TEST_AMQP_URL"))

  setup do
    url = System.get_env("ACKNOWLEDGMENTS_TEST_AMQP_URL")
    if !url, do: flunk("Set ACKNOWLEDGMENTS_TEST_AMQP_URL for RabbitMQ integration tests")

    config = [
      url: url,
      source: "test",
      queue: "custyard.test.#{System.unique_integer([:positive])}",
      retry_delays: [100]
    ]

    {:ok, connection, channel} = Broker.open(config)
    assert :ok = Topology.provision(channel, config)

    on_exit(fn ->
      for queue <- [config[:queue], Topology.failure(config), Topology.retry(config, 1)],
          do: AMQP.Queue.delete(channel, queue)

      AMQP.Connection.close(connection)
    end)

    %{connection: connection, channel: channel, config: config}
  end

  test "confirms routing and retains exact evidence through delayed retry", %{
    connection: connection,
    channel: channel,
    config: config
  } do
    body = ~s({"submission_id":"stable"})

    assert :ok =
             Broker.publish(
               connection,
               Topology.retry(config, 1),
               body,
               [{"custyard-attempt", :long, 1}],
               5_000
             )

    assert {:empty, _} = AMQP.Basic.get(channel, config[:queue])
    Process.sleep(250)
    assert {:ok, ^body, meta} = AMQP.Basic.get(channel, config[:queue], no_ack: false)
    assert meta.persistent
    assert :ok = AMQP.Basic.ack(channel, meta.delivery_tag)
  end

  test "an unroutable confirmed publication is rejected", %{
    connection: connection,
    config: config
  } do
    assert {:error, {:unroutable, 312}} =
             Broker.publish(connection, config[:queue] <> ".missing", "original", [], 5_000)

    assert :ok = Broker.publish(connection, config[:queue], "next", [], 5_000)
  end

  test "closing before acknowledgement redelivers committed payload", %{
    connection: connection,
    channel: channel,
    config: config
  } do
    assert :ok = Broker.publish(connection, config[:queue], "evidence", [], 5_000)
    {:ok, disposable} = AMQP.Channel.open(connection)
    assert {:ok, "evidence", _} = AMQP.Basic.get(disposable, config[:queue], no_ack: false)
    :ok = AMQP.Channel.close(disposable)
    assert {:ok, "evidence", meta} = AMQP.Basic.get(channel, config[:queue], no_ack: false)
    assert meta.redelivered
    assert :ok = AMQP.Basic.ack(channel, meta.delivery_tag)
  end
end
