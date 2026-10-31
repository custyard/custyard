defmodule Custyard.Acknowledgments.TransportTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias Custyard.Acknowledgments.{Broker, Config, Consumer, Topology}

  setup do
    key = {Consumer, :status}
    previous = :persistent_term.get(key, :absent)

    on_exit(fn ->
      if previous == :absent,
        do: :persistent_term.erase(key),
        else: :persistent_term.put(key, previous)
    end)

    :ok
  end

  test "invalid broker URLs retain the fixed failure reason and schedule a safe retry" do
    url = "invalid://broker-user:BROKER_PASSWORD_CANARY@broker.invalid"
    state = disconnected_state(url)
    assert Config.network_params(url) == :error

    log =
      capture_log(
        [format: "$metadata$message", metadata: [:reason, :outcome, :retry_after_ms]],
        fn ->
          assert {:noreply, ^state} = Consumer.handle_info(:connect, state)
        end
      )

    assert log =~ "acknowledgment_broker_unavailable"
    assert log =~ "reason=invalid_url"
    assert log =~ "outcome=retrying"
    assert log =~ "retry_after_ms=1"
    refute log =~ url
    refute log =~ "BROKER_PASSWORD_CANARY"
    refute log =~ "broker-user"
    refute log =~ "broker.invalid"
    assert_receive :connect, 200
  end

  test "arbitrary monitored-process failures cannot enter reconnect diagnostics" do
    url = "invalid://broker-user:BROKER_PASSWORD_CANARY@broker.invalid"
    ref = make_ref()
    state = %{disconnected_state(url) | monitors: [ref]}
    reason = {:shutdown, %{url: url, state: "CUSTOMER_CONTENT_CANARY"}}

    log =
      capture_log([format: "$metadata$message", metadata: [:reason, :outcome]], fn ->
        assert {:noreply, reset} =
                 Consumer.handle_info({:DOWN, ref, :process, self(), reason}, state)

        assert reset.monitors == []
        assert reset.connection == nil
        assert reset.channel == nil
      end)

    assert log =~ "acknowledgment_broker_unavailable"
    assert log =~ "reason=unclassified_error"
    assert log =~ "outcome=retrying"
    refute log =~ "BROKER_PASSWORD_CANARY"
    refute log =~ "CUSTOMER_CONTENT_CANARY"
    assert_receive :connect, 200
  end

  test "every broker-open failure category survives the log schema" do
    for category <- Broker.open_failure_categories() do
      assert Custyard.Log.sanitize_metadata(Custyard.Log.failure(category))[:reason] ==
               Atom.to_string(category)
    end
  end

  test "source attribution comes from the subscription" do
    assert {:error, :source_mismatch} =
             Consumer.process(~s({"source":"other-production"}), "ots-production")

    assert {:error, :invalid_json} = Consumer.process("not json", "ots-production")
    assert {:error, :invalid_json} = Consumer.process("[]", "ots-production")
  end

  test "stale subscription deliveries cannot acknowledge the current channel" do
    state = %{channel: :current_channel, consumer_tag: "current"}

    assert {:noreply, ^state} =
             Consumer.handle_info(
               {:basic_deliver, "evidence", %{consumer_tag: "old", delivery_tag: 1}},
               state
             )
  end

  test "storage failures become delayed retry outcomes" do
    body = ~s({"source":"ots-production"})

    assert {:error, :storage_unavailable} =
             Consumer.process(body, "ots-production", fn _ -> raise "database unavailable" end)

    assert {:error, :storage_unavailable} =
             Consumer.process(body, "ots-production", fn _ -> exit(:database_unavailable) end)

    assert {:error, :message_too_large} =
             Consumer.process(String.duplicate("x", 65_537), "ots-production")
  end

  test "retry headers accept only nonnegative integers" do
    assert Consumer.attempts(nil) == 0
    # amqp_client reports a message published without headers as :undefined.
    assert Consumer.attempts(:undefined) == 0
    assert Consumer.attempts([{"custyard-attempt", :long, 2}]) == 2
    assert Consumer.attempts([{"custyard-attempt", :longstr, "2"}]) == 0
    assert Consumer.attempts([{"custyard-attempt", :long, -1}]) == 0
  end

  test "configuration requires explicit source and positive bounded consumption" do
    assert_raise ArgumentError, fn ->
      Config.validate!(url: "amqp://localhost", queue: "test", prefetch: 1, retry_delays: [])
    end

    assert_raise ArgumentError, fn ->
      Config.validate!(
        url: "amqp://localhost",
        source: "test",
        queue: "test",
        prefetch: 0,
        retry_delays: []
      )
    end

    assert Topology.failure(queue: "source-one") != Topology.failure(queue: "source-two")
  end

  defp disconnected_state(url) do
    %{
      config: [url: url, reconnect_delay: 1],
      connection: nil,
      channel: nil,
      monitors: [],
      consumer_tag: nil
    }
  end
end
