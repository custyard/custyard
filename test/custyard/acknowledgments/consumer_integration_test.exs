defmodule Custyard.Acknowledgments.ConsumerIntegrationTest do
  use Custyard.DataCase, async: false
  import Custyard.Factory
  alias Custyard.Acknowledgments
  alias Custyard.Acknowledgments.{Broker, Consumer, Topology}

  @moduletag :rabbitmq
  @moduletag skip: is_nil(System.get_env("ACKNOWLEDGMENTS_TEST_AMQP_URL"))

  setup do
    config = [
      url: System.get_env("ACKNOWLEDGMENTS_TEST_AMQP_URL"),
      source: "ots.integration",
      queue: "custyard.consumer.test.#{System.unique_integer([:positive])}",
      prefetch: 1,
      retry_delays: [50],
      confirm_timeout: 5_000,
      reconnect_delay: 50
    ]

    {:ok, connection, channel} = Broker.open(config)
    :ok = Topology.provision(channel, config)
    org = insert_organization()

    on_exit(fn ->
      case Broker.open(config) do
        {:ok, cleanup_connection, cleanup_channel} ->
          for queue <- [config[:queue], Topology.failure(config), Topology.retry(config, 1)] do
            AMQP.Queue.delete(cleanup_channel, queue)
          end

          AMQP.Connection.close(cleanup_connection)

        _ ->
          :ok
      end

      if Process.alive?(connection.pid), do: AMQP.Connection.close(connection)
    end)

    %{config: config, connection: connection, channel: channel, org: org}
  end

  defp evidence(attrs \\ %{}) do
    text = "Versioned Colonel statement\n  preserved exactly"

    Map.merge(
      %{
        "schema_version" => 1,
        "source" => "ots.integration",
        "submission_id" => "stable",
        "organization_id" => "ots-org",
        "actor_id" => "operator",
        "actor_role" => "colonel",
        "actor_type" => "internal_operator",
        "statement_key" => "pilot",
        "statement_version" => "v1",
        "statement_text" => text,
        "statement_hash" => Base.encode16(:crypto.hash(:sha256, text), case: :lower),
        "acknowledged_at" => "2026-09-30T17:31:42Z"
      },
      attrs
    )
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

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    case fun.() do
      false ->
        Process.sleep(20)
        eventually(fun, attempts - 1)

      nil ->
        Process.sleep(20)
        eventually(fun, attempts - 1)

      result ->
        result
    end
  end

  defp eventually(_, 0), do: flunk("RabbitMQ condition did not converge")

  defp get_failed(channel, config) do
    eventually(fn ->
      case AMQP.Basic.get(channel, Topology.failure(config), no_ack: false) do
        {:ok, body, meta} -> {body, meta}
        {:empty, _} -> false
      end
    end)
  end

  test "missing topology reconnects until provisioned, then consumes", ctx do
    bind(ctx.org)
    {:ok, _} = AMQP.Queue.delete(ctx.channel, ctx.config[:queue])
    consumer = start_consumer(ctx.config)
    Process.sleep(ctx.config[:reconnect_delay] * 4)
    assert Process.alive?(consumer)
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
      {retained, meta} = get_failed(ctx.channel, ctx.config)
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

  test "unmapped evidence retries then replays after binding with original identity", ctx do
    body = Jason.encode!(evidence())
    consumer = start_consumer(ctx.config)
    :ok = Broker.publish(ctx.connection, ctx.config[:queue], body, [], 5_000)
    {^body, meta} = get_failed(ctx.channel, ctx.config)
    assert Acknowledgments.list_for_organization(ctx.org.id) == []
    bind(ctx.org)
    :ok = Broker.publish(ctx.connection, ctx.config[:queue], body, [], 5_000)
    :ok = AMQP.Basic.ack(ctx.channel, meta.delivery_tag)
    eventually(fn -> length(Acknowledgments.list_for_organization(ctx.org.id)) == 1 end)
    assert [record] = Acknowledgments.list_for_organization(ctx.org.id)
    assert record.submission_id == "stable"
    assert record.acknowledged_at == evidence()["acknowledged_at"]
    eventually(fn -> drained(ctx.config, ctx.channel, consumer) end)
    stop_supervised!(Consumer)
    assert {:empty, _} = AMQP.Basic.get(ctx.channel, ctx.config[:queue], no_ack: false)
  end
end
