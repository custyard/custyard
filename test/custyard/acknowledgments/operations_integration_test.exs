defmodule Custyard.Acknowledgments.OperationsIntegrationTest do
  use Custyard.DataCase, async: false
  import Custyard.AcknowledgmentsBroker
  alias Custyard.{Acknowledgments, AuditEvent}
  alias Custyard.Acknowledgments.{Operations, Topology}

  @moduletag :rabbitmq
  @moduletag skip: is_nil(System.get_env("ACKNOWLEDGMENTS_TEST_AMQP_URL"))

  setup do
    setup_topology(retry_delays: [50, 60])
  end

  defp failed_queue(ctx), do: Topology.failure(ctx.config)
  defp body(submission_id), do: Jason.encode!(evidence(%{"submission_id" => submission_id}))

  describe "status" do
    test "reports ready and consumer counts for every queue, in order", ctx do
      put_failure(ctx, body("one"))
      await_failures(ctx, 1)

      assert {:ok, queues} = Operations.status()

      assert Enum.map(queues, & &1.role) == [:work, {:retry, 1}, {:retry, 2}, :failed]
      assert %{queue: queue, ready: 0, consumers: 0} = hd(queues)
      assert queue == ctx.config[:queue]
      assert %{ready: 1} = List.last(queues)
    end

    test "a missing queue is reported per queue, not as a failed status", ctx do
      {:ok, _} = AMQP.Queue.delete(ctx.channel, Topology.retry(ctx.config, 2))

      assert {:ok, queues} = Operations.status()
      assert %{role: {:retry, 2}, error: :queue_missing} = Enum.at(queues, 2)
      assert %{role: :failed, ready: 0} = List.last(queues)
    end

    test "an unusable configuration is a fixed error, not a raise" do
      Application.put_env(:custyard, :acknowledgments, url: nil, source: nil)
      assert Operations.status() == {:error, :invalid_config}
      assert Operations.error_message(:invalid_config) =~ "missing or invalid"
    end
  end

  describe "failure_summary/0" do
    test "returns only sanitized fields and leaves the message at the head", ctx do
      put_failure(ctx, body("first"))
      put_failure(ctx, body("second"))
      await_failures(ctx, 2)

      expected = %{
        readable: true,
        source: "ots.integration",
        submission_id: "first",
        category: "unmapped_organization",
        attempt: 4
      }

      assert Operations.failure_summary() == {:ok, expected}
      await_failures(ctx, 2)
      # A reject with requeue would have moved "first" behind "second".
      assert Operations.failure_summary() == {:ok, expected}
    end

    test "an unreadable body hides its identity; unknown headers are not shown", ctx do
      put_failure(ctx, "{not json", [
        {"custyard-attempt", :long, -3},
        {"custyard-failure", :longstr, "\e[31mforged"}
      ])

      await_failures(ctx, 1)

      assert Operations.failure_summary() ==
               {:ok,
                %{readable: false, source: nil, submission_id: nil, category: nil, attempt: nil}}
    end

    test "an invalid identity or an oversized body is unreadable", ctx do
      put_failure(ctx, body("bad\nid"))
      await_failures(ctx, 1)
      assert {:ok, %{readable: false, submission_id: nil}} = Operations.failure_summary()

      {:ok, _} = AMQP.Queue.purge(ctx.channel, failed_queue(ctx))
      oversized = Jason.encode!(evidence(%{"statement_text" => String.duplicate("x", 70_000)}))
      put_failure(ctx, oversized)
      await_failures(ctx, 1)
      assert {:ok, %{readable: false, source: nil}} = Operations.failure_summary()
    end

    test "an empty failure queue is :empty" do
      assert Operations.failure_summary() == :empty
    end
  end

  describe "guarded replay" do
    test "replays only while the inspected message is still the oldest", ctx do
      put_failure(ctx, body("first"))
      put_failure(ctx, body("second"))
      await_failures(ctx, 2)

      assert Operations.replay("second") == {:error, :changed}
      await_failures(ctx, 2)
      assert {:ok, %{submission_id: "first"}} = Operations.failure_summary()

      assert Operations.replay("first") == :ok
      await_failures(ctx, 1)
      assert {:ok, %{submission_id: "second"}} = Operations.failure_summary()
      assert {:ok, replayed, _} = AMQP.Basic.get(ctx.channel, ctx.config[:queue], no_ack: true)
      assert replayed == body("first")
    end

    test "an unreadable head never matches an expected submission", ctx do
      put_failure(ctx, "{not json")
      await_failures(ctx, 1)

      assert Operations.replay("anything") == {:error, :changed}
      await_failures(ctx, 1)
    end
  end

  describe "replay_failure/2 audit" do
    defp replay_audits,
      do: Repo.all(from e in AuditEvent, where: e.event_type == :acknowledgment_replayed)

    test "records operator, sanitized identity and outcome", ctx do
      operator = Custyard.Factory.insert_operator_account()
      put_failure(ctx, body("audited"))
      await_failures(ctx, 1)

      assert Acknowledgments.replay_failure("other", operator) == {:error, :changed}
      assert Acknowledgments.replay_failure("audited", operator) == :ok

      assert [changed, replayed] = Enum.sort_by(replay_audits(), & &1.id)
      assert changed.payload["outcome"] == "changed"
      assert replayed.source == "operator"

      assert replayed.payload == %{
               "actor" => "operator",
               "operator_id" => operator.id,
               "operator_email" => operator.email,
               "source" => "ots.integration",
               "submission_id" => "audited",
               "category" => "unmapped_organization",
               "attempt" => 4,
               "outcome" => "replayed"
             }
    end

    test "release replays are audited with the channel, including empty ones" do
      assert Acknowledgments.replay_failure(nil, "cli") == :empty

      assert [%{source: "cli", payload: %{"actor" => "cli", "outcome" => "empty"}}] =
               replay_audits()
    end
  end

  # LiveView async tasks are linked to the view and die with it, but AMQP
  # connections are not linked to their opener: without the guard the fetched
  # message would stay unacknowledged on a leaked channel.
  test "killing the caller mid-inspect closes the connection and returns the message", ctx do
    put_failure(ctx, body("held"))
    await_failures(ctx, 1)
    test = self()

    caller =
      spawn(fn ->
        Operations.with_channel(fn channel, connection, config ->
          {:ok, _, _} = AMQP.Basic.get(channel, Topology.failure(config), no_ack: false)
          send(test, {:holding, connection})
          Process.sleep(:infinity)
        end)
      end)

    assert_receive {:holding, connection}, 5_000
    connection_monitor = Process.monitor(connection.pid)
    # Held unacknowledged: nothing ready while the caller lives.
    assert ready_count(ctx, failed_queue(ctx)) == 0

    Process.exit(caller, :kill)

    assert_receive {:DOWN, ^connection_monitor, :process, _, _}, 5_000
    await_failures(ctx, 1)
    assert {:ok, %{submission_id: "held"}} = Operations.failure_summary()
  end

  test "a completed operation closes its connection", ctx do
    test = self()

    assert :done =
             Operations.with_channel(fn _channel, connection, _config ->
               send(test, {:connection, connection})
               :done
             end)

    assert_receive {:connection, connection}
    monitor = Process.monitor(connection.pid)
    assert_receive {:DOWN, ^monitor, :process, _, _}, 5_000
    assert ready_count(ctx, failed_queue(ctx)) == 0
  end
end
