defmodule Custyard.Acknowledgments.TransportTest do
  use ExUnit.Case, async: true
  alias Custyard.Acknowledgments.{Config, Consumer, Topology}

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
end
