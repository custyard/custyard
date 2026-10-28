defmodule Custyard.AcknowledgmentsBroker do
  @moduledoc """
  RabbitMQ fixtures shared by the acknowledgment integration tests: a
  provisioned topology with a unique queue name per test, loaded as the
  application's acknowledgment configuration the way release and Mix commands
  read it, and removed afterwards. Polling is bounded; nothing sleeps for a
  fixed time to wait for the broker.
  """
  import ExUnit.Assertions
  import ExUnit.Callbacks, only: [on_exit: 1]
  alias Custyard.Acknowledgments.{Broker, Topology}

  def url, do: System.get_env("ACKNOWLEDGMENTS_TEST_AMQP_URL")

  @doc "A queue name unique across test runs that share one broker."
  def unique_queue(prefix) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
    "#{prefix}.#{System.unique_integer([:positive])}.#{suffix}"
  end

  @doc """
  Provisions a topology, installs it as the application configuration and
  returns `%{tenant: tenant, config: config, connection: connection, channel: channel}`.
  """
  def setup_topology(overrides \\ []) do
    if !url(), do: flunk("Set ACKNOWLEDGMENTS_TEST_AMQP_URL for RabbitMQ integration tests")

    tenant = Custyard.Factory.insert_tenant()
    Process.put(:ack_test_tenant_id, tenant.id)

    config =
      Keyword.merge(
        [
          tenant_id: tenant.id,
          enabled: true,
          url: url(),
          source: "ots.integration",
          queue: unique_queue("custyard.consumer.test"),
          prefetch: 1,
          retry_delays: [50],
          confirm_timeout: 5_000,
          reconnect_delay: 50
        ],
        overrides
      )

    {:ok, connection, channel} = Broker.open(config)
    :ok = Topology.provision(channel, config)

    previous = Application.get_env(:custyard, :acknowledgments)
    Application.put_env(:custyard, :acknowledgments, config)

    {:ok, _} =
      Custyard.Acknowledgments.configure_integration(
        Custyard.Scope.for_staff(
          Custyard.Factory.insert_operator_account(tenant_id: tenant.id, role: "admin"),
          tenant
        ),
        Map.new(config)
      )

    on_exit(fn ->
      Application.put_env(:custyard, :acknowledgments, previous)
      delete_topology(config)
      if Process.alive?(connection.pid), do: AMQP.Connection.close(connection)
    end)

    %{tenant: tenant, config: config, connection: connection, channel: channel}
  end

  defp delete_topology(config) do
    case Broker.open(config) do
      {:ok, connection, channel} ->
        queues =
          [config[:queue], Topology.failure(config)] ++
            Enum.map(1..length(config[:retry_delays]), &Topology.retry(config, &1))

        Enum.each(queues, &AMQP.Queue.delete(channel, &1))
        AMQP.Connection.close(connection)

      _ ->
        :ok
    end
  end

  def evidence(attrs \\ %{}) do
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

  @doc "Places a message directly in the failure queue, as the consumer would."
  def put_failure(ctx, body, headers \\ nil) do
    headers =
      headers ||
        [{"custyard-attempt", :long, 4}, {"custyard-failure", :longstr, "unmapped_organization"}]

    :ok = Broker.publish(ctx.connection, Topology.failure(ctx.config), body, headers, 5_000)
  end

  def eventually(fun, attempts \\ 100)

  def eventually(fun, attempts) when attempts > 0 do
    case fun.() do
      falsy when falsy in [false, nil] ->
        Process.sleep(20)
        eventually(fun, attempts - 1)

      result ->
        result
    end
  end

  def eventually(_, 0), do: flunk("RabbitMQ condition did not converge")

  @doc "Ready (not unacknowledged) messages in a queue, via a passive declare."
  def ready_count(ctx, queue) do
    {:ok, %{message_count: count}} = AMQP.Queue.declare(ctx.channel, queue, passive: true)
    count
  end

  # Counts ready messages only, so this also waits for a returned delivery.
  def await_failures(ctx, count) do
    eventually(fn -> ready_count(ctx, Topology.failure(ctx.config)) == count end)
  end

  def get_failed(ctx) do
    eventually(fn ->
      case AMQP.Basic.get(ctx.channel, Topology.failure(ctx.config), no_ack: false) do
        {:ok, body, meta} -> {body, meta}
        {:empty, _} -> false
      end
    end)
  end
end
