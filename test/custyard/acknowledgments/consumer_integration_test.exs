defmodule Custyard.Acknowledgments.ConsumerIntegrationTest do
  use Custyard.DataCase, async: false
  import Custyard.Factory
  import Custyard.AcknowledgmentsBroker
  alias Custyard.Acknowledgments
  alias Custyard.Acknowledgments.{Broker, Consumer, Operations, Topology}

  @moduletag :rabbitmq
  @moduletag skip: is_nil(System.get_env("ACKNOWLEDGMENTS_TEST_AMQP_URL"))

  # Recovery operations load configuration as the Mix and release commands do.
  setup do
    Map.put(setup_topology(), :org, insert_organization())
  end

  defp bind(org) do
    {:ok, _} =
      Acknowledgments.create_binding(%{
        source: "ots.integration",
        source_organization_id: "ots-org",
        organization_id: org.id
      })
  end

  defp start_consumer(config), do: start_supervised!({Consumer, config: config})

  # A synchronous channel round trip ensures the prior delivery ack was sent.
  defp drained(config, channel, consumer) do
    state = :sys.get_state(consumer)
    {:ok, _} = AMQP.Queue.declare(state.channel, config[:queue], passive: true)

    case AMQP.Basic.get(channel, config[:queue], no_ack: false) do
      {:empty, _} ->
        true

      {:ok, _, meta} ->
        AMQP.Basic.nack(channel, meta.delivery_tag, requeue: true)
        false
    end
  end

  test "missing topology reconnects until provisioned, then consumes", ctx do
    bind(ctx.org)
    {:ok, _} = AMQP.Queue.delete(ctx.channel, ctx.config[:queue])
    consumer = start_consumer(ctx.config)
    Process.sleep(ctx.config[:reconnect_delay] * 4)
    assert Process.alive?(consumer)
    assert Consumer.status() == :connecting
    assert :ok = Topology.provision(ctx.channel, ctx.config)
    body = Jason.encode!(evidence())
    assert :ok = Broker.publish(ctx.connection, ctx.config[:queue], body, [], 5_000)
    eventually(fn -> length(Acknowledgments.list_for_organization(ctx.org.id)) == 1 end)
    eventually(fn -> drained(ctx.config, ctx.channel, consumer) end)
    stop_supervised!(Consumer)
    assert {:empty, _} = AMQP.Basic.get(ctx.channel, ctx.config[:queue], no_ack: false)
  end

  test "queued while consumer is down, duplicates commit exactly once", ctx do
    bind(ctx.org)
    body = Jason.encode!(evidence())
    :ok = Broker.publish(ctx.connection, ctx.config[:queue], body, [], 5_000)
    :ok = Broker.publish(ctx.connection, ctx.config[:queue], body, [], 5_000)
    consumer = start_consumer(ctx.config)
    eventually(fn -> length(Acknowledgments.list_for_organization(ctx.org.id)) == 1 end)

    eventually(fn -> drained(ctx.config, ctx.channel, consumer) end)

    assert [record] = Acknowledgments.list_for_organization(ctx.org.id)
    assert record.statement_text == evidence()["statement_text"]
    stop_supervised!(Consumer)
    assert {:empty, _} = AMQP.Basic.get(ctx.channel, ctx.config[:queue], no_ack: false)
  end

  test "commit followed by channel loss redelivers to consumer without second record", ctx do
    bind(ctx.org)
    body = Jason.encode!(evidence())
    :ok = Broker.publish(ctx.connection, ctx.config[:queue], body, [], 5_000)
    {:ok, disposable} = AMQP.Channel.open(ctx.connection)
    {:ok, ^body, _meta} = AMQP.Basic.get(disposable, ctx.config[:queue], no_ack: false)
    assert {:ok, record} = Consumer.process(body, ctx.config[:source])
    :ok = AMQP.Channel.close(disposable)
    consumer = start_consumer(ctx.config)

    eventually(fn -> drained(ctx.config, ctx.channel, consumer) end)

    assert [persisted] = Acknowledgments.list_for_organization(ctx.org.id)
    assert persisted.id == record.id
    stop_supervised!(Consumer)
    assert {:empty, _} = AMQP.Basic.get(ctx.channel, ctx.config[:queue], no_ack: false)
  end

  test "malformed, wrong source, and conflicting evidence stay recoverable", ctx do
    bind(ctx.org)
    assert {:ok, original} = Acknowledgments.ingest(evidence())
    _consumer = start_consumer(ctx.config)

    bodies = [
      "{invalid",
      Jason.encode!(evidence(%{"source" => "other.production"})),
      Jason.encode!(evidence(%{"actor_id" => "different-operator"}))
    ]

    Enum.each(bodies, fn body ->
      :ok = Broker.publish(ctx.connection, ctx.config[:queue], body, [], 5_000)
      {retained, meta} = get_failed(ctx)
      assert retained == body
      assert List.keyfind(meta.headers, "custyard-attempt", 0) == {"custyard-attempt", :long, 2}
      assert List.keyfind(meta.headers, "custyard-failure", 0)
      :ok = AMQP.Basic.ack(ctx.channel, meta.delivery_tag)
    end)

    assert [unchanged] = Acknowledgments.list_for_organization(ctx.org.id)
    assert unchanged.id == original.id
    assert unchanged.actor_id == original.actor_id
    stop_supervised!(Consumer)
    assert {:empty, _} = AMQP.Basic.get(ctx.channel, ctx.config[:queue], no_ack: false)
  end

  # The producer contract requires no headers, and amqp_client reports their
  # absence as :undefined rather than an empty list.
  test "a failing message published without headers retries without crashing", ctx do
    consumer = start_consumer(ctx.config)
    body = Jason.encode!(evidence())
    :ok = AMQP.Basic.publish(ctx.channel, "", ctx.config[:queue], body, persistent: true)

    {^body, meta} = get_failed(ctx)
    assert List.keyfind(meta.headers, "custyard-attempt", 0) == {"custyard-attempt", :long, 2}

    assert List.keyfind(meta.headers, "custyard-failure", 0) ==
             {"custyard-failure", :longstr, "unmapped_organization"}

    :ok = AMQP.Basic.ack(ctx.channel, meta.delivery_tag)
    assert Process.whereis(Consumer) == consumer
  end

  test "status is published without calling the consumer", ctx do
    Application.put_env(:custyard, :acknowledgments, Keyword.put(ctx.config, :enabled, true))
    assert Acknowledgments.subscription_status() == :connecting

    consumer = start_consumer(ctx.config)
    eventually(fn -> Acknowledgments.subscription_status() == :connected end)

    # A busy consumer cannot delay the answer: suspend it and ask again.
    :sys.suspend(consumer)
    assert Acknowledgments.subscription_status() == :connected
    :sys.resume(consumer)

    stop_supervised!(Consumer)
    assert Acknowledgments.subscription_status() == :connecting
  end

  test "the consumer's status and crash reports never render the broker URL", ctx do
    consumer = start_consumer(ctx.config)
    eventually(fn -> Consumer.status() == :connected end)

    status = consumer |> :sys.get_status() |> inspect(limit: :infinity)
    refute status =~ ctx.config[:url]
    refute status =~ URI.parse(ctx.config[:url]).userinfo
    assert status =~ "[REDACTED]"

    # An unknown call is answered, not a crash with the state in the report.
    assert GenServer.call(Consumer, :unexpected) == {:error, :unsupported}
    assert Process.whereis(Consumer) == consumer
  end

  test "unmapped evidence retries then replays after binding with original identity", ctx do
    body = Jason.encode!(evidence())
    consumer = start_consumer(ctx.config)
    :ok = Broker.publish(ctx.connection, ctx.config[:queue], body, [], 5_000)
    {^body, meta} = get_failed(ctx)
    :ok = AMQP.Basic.reject(ctx.channel, meta.delivery_tag, requeue: true)
    await_failures(ctx, 1)
    assert Acknowledgments.list_for_organization(ctx.org.id) == []
    bind(ctx.org)
    assert :ok = Operations.replay(nil, "console")
    eventually(fn -> length(Acknowledgments.list_for_organization(ctx.org.id)) == 1 end)
    assert [record] = Acknowledgments.list_for_organization(ctx.org.id)
    assert record.submission_id == "stable"
    assert record.acknowledged_at == evidence()["acknowledged_at"]
    eventually(fn -> drained(ctx.config, ctx.channel, consumer) end)
    await_failures(ctx, 0)
    assert :empty = Operations.replay(nil, "console")
    stop_supervised!(Consumer)
    assert {:empty, _} = AMQP.Basic.get(ctx.channel, ctx.config[:queue], no_ack: false)
  end

  test "inspect returns the failure to its queue, and an unroutable replay keeps it", ctx do
    assert :empty = Operations.inspect_failure()
    body = Jason.encode!(evidence())
    start_consumer(ctx.config)
    :ok = Broker.publish(ctx.connection, ctx.config[:queue], body, [], 5_000)
    await_failures(ctx, 1)
    stop_supervised!(Consumer)

    assert {:ok, %{body: ^body, summary: summary}} = Operations.inspect_failure()
    assert %{attempt: 2, category: "unmapped_organization", submission_id: "stable"} = summary
    await_failures(ctx, 1)

    {:ok, _} = AMQP.Queue.delete(ctx.channel, ctx.config[:queue])
    assert {:error, {:unroutable, 312}} = Operations.replay(nil, "console")
    await_failures(ctx, 1)
    assert {^body, meta} = get_failed(ctx)
    :ok = AMQP.Basic.ack(ctx.channel, meta.delivery_tag)
  end
end
