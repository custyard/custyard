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
      queue: Custyard.AcknowledgmentsBroker.unique_queue("custyard.test"),
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

  # TTL expiry and dead-lettering are asynchronous, so poll within a bound instead of sleeping.
  defp await_message(channel, queue, attempts \\ 250) do
    case AMQP.Basic.get(channel, queue, no_ack: false) do
      {:empty, _} when attempts > 1 ->
        Process.sleep(20)
        await_message(channel, queue, attempts - 1)

      result ->
        result
    end
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
    assert {:ok, ^body, meta} = await_message(channel, config[:queue])
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

  # amqp_client errors can embed the URI with its password; open/1 reports a
  # fixed atom for each kind of failure instead.
  test "connection failures are fixed atoms that carry no credentials", %{config: config} do
    uri = URI.parse(config[:url])
    [user, _password] = String.split(uri.userinfo, ":", parts: 2)
    with_url = fn url -> Keyword.put(config, :url, url) end

    wrong_password = URI.to_string(%{uri | userinfo: "#{user}:not-the-password"})
    assert Broker.open(with_url.(wrong_password)) == {:error, :auth_failed}

    missing_vhost = URI.to_string(%{uri | path: "/custyard-missing-vhost"})
    assert Broker.open(with_url.(missing_vhost)) == {:error, :access_refused}

    closed_port =
      URI.to_string(%{uri | userinfo: "#{user}:secret-pw", host: "127.0.0.1", port: 1})

    assert Broker.open(with_url.(closed_port)) == {:error, :unreachable}

    # A parse error would otherwise return {:error, {reason, full_uri}}.
    assert Broker.open(with_url.("amqp://#{user}:secret-pw@localhost:99999")) ==
             {:error, :invalid_url}

    assert Broker.open(with_url.("amqp://")) == {:error, :invalid_url}
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
