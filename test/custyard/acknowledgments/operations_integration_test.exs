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
  defp sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)

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
        attempt: 4,
        body_sha256: sha256(body("first"))
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
                %{
                  readable: false,
                  source: nil,
                  submission_id: nil,
                  category: nil,
                  attempt: nil,
                  body_sha256: sha256("{not json")
                }}
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

      assert Operations.replay("second", "console") == {:error, :changed}
      await_failures(ctx, 2)
      assert {:ok, %{submission_id: "first"}} = Operations.failure_summary()

      assert Operations.replay("first", "console") == :ok
      await_failures(ctx, 1)
      assert {:ok, %{submission_id: "second"}} = Operations.failure_summary()
      assert {:ok, replayed, _} = AMQP.Basic.get(ctx.channel, ctx.config[:queue], no_ack: true)
      assert replayed == body("first")
    end

    test "an unreadable head never matches an expected submission", ctx do
      put_failure(ctx, "{not json")
      await_failures(ctx, 1)

      assert Operations.replay("anything", "console") == {:error, :changed}
      await_failures(ctx, 1)
    end

    # Conflicting evidence reuses a submission ID, so two retained failures can
    # share one; the inspected body digest tells them apart.
    test "the inspected body must match too, not only the submission ID", ctx do
      original = body("shared")
      conflicting = Jason.encode!(evidence(%{"submission_id" => "shared", "actor_id" => "other"}))
      put_failure(ctx, original)
      put_failure(ctx, conflicting)
      await_failures(ctx, 2)

      assert {:ok, %{submission_id: "shared", body_sha256: inspected}} =
               Operations.failure_summary()

      assert inspected == sha256(original)
      await_failures(ctx, 2)

      # The inspected message leaves the queue another way before the replay.
      {^original, meta} = get_failed(ctx)
      :ok = AMQP.Basic.ack(ctx.channel, meta.delivery_tag)

      expected = %{submission_id: "shared", body_sha256: inspected}
      assert Operations.replay(expected, "console") == {:error, :changed}
      await_failures(ctx, 1)
      assert {:empty, _} = AMQP.Basic.get(ctx.channel, ctx.config[:queue], no_ack: true)

      matching = %{submission_id: "shared", body_sha256: sha256(conflicting)}
      assert Operations.replay(matching, "console") == :ok

      assert {:ok, ^conflicting, _} =
               AMQP.Basic.get(ctx.channel, ctx.config[:queue], no_ack: true)
    end
  end

  describe "replay audit" do
    defp replay_audits,
      do: Repo.all(from e in AuditEvent, where: e.event_type == :acknowledgment_replayed)

    test "records operator, sanitized identity, body digest and outcome", ctx do
      operator = Custyard.Factory.insert_operator_account()
      put_failure(ctx, body("audited"))
      await_failures(ctx, 1)

      assert Operations.replay("other", operator) == {:error, :changed}
      assert Operations.replay("audited", operator) == :ok

      assert [changed, started, replayed] = Enum.sort_by(replay_audits(), & &1.id)
      assert changed.payload["outcome"] == "changed"
      assert replayed.source == "operator"
      assert started.payload == %{replayed.payload | "outcome" => "started"}

      assert replayed.payload == %{
               "actor" => "operator",
               "operator_id" => operator.id,
               "operator_email" => operator.email,
               "source" => "ots.integration",
               "submission_id" => "audited",
               "body_sha256" => sha256(body("audited")),
               "category" => "unmapped_organization",
               "attempt" => 4,
               "outcome" => "replayed"
             }
    end

    test "nothing is replayed when the attempt cannot be audited", ctx do
      put_failure(ctx, body("unaudited"))
      await_failures(ctx, 1)

      # SQLite DDL is transactional, so the sandbox drops the trigger again.
      Repo.query!(
        "CREATE TRIGGER refuse_audit BEFORE INSERT ON audit_events " <>
          "BEGIN SELECT RAISE(ABORT, 'audit unavailable'); END"
      )

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert Operations.replay("unaudited", "cli") == {:error, :audit_failed}
        end)

      assert log =~ "Failed to record acknowledgment_replayed audit event"
      assert Operations.error_message(:audit_failed) =~ "nothing was replayed"
      Repo.query!("DROP TRIGGER refuse_audit")

      assert replay_audits() == []
      assert {:ok, %{submission_id: "unaudited"}} = Operations.failure_summary()
      assert {:empty, _} = AMQP.Basic.get(ctx.channel, ctx.config[:queue], no_ack: true)
    end

    test "release replays are audited with the channel, including empty ones" do
      assert Operations.replay(nil, "cli") == :empty

      assert [%{source: "cli", payload: %{"actor" => "cli", "outcome" => "empty"}}] =
               replay_audits()
    end

    test "there is no unaudited replay entry point", ctx do
      Code.ensure_loaded!(Operations)

      for {name, arity} <- [replay: 0, replay: 1, replay_head: 1],
          do: refute(function_exported?(Operations, name, arity))

      refute function_exported?(Acknowledgments, :replay_failure, 2)

      # An actor that cannot be recorded is refused before any broker work.
      put_failure(ctx, body("kept"))
      await_failures(ctx, 1)
      assert_raise ArgumentError, fn -> Operations.replay(nil, "someone") end
      assert_raise ArgumentError, fn -> Operations.replay(nil, nil) end
      await_failures(ctx, 1)
      assert replay_audits() == []
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
