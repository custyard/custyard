defmodule CustyardWeb.TelemetryTest do
  @moduledoc """
  Guards the contract between what the app *emits* and what `metrics/0`
  *declares*.

  Nothing consumes `metrics/0` yet (see the module's own moduledoc and
  custyard/custyard#11), which means a declaration that does not match its
  event — a wrong name, a tag the emit site never sets — would stay invisible
  until the day a reporter is attached, and then surface as a missing chart
  rather than as a test failure. These tests close that gap for the events the
  supervisor itself emits.
  """
  use Custyard.DataCase, async: true

  import Custyard.Factory

  alias Custyard.Conversation

  # Deliberately NOT `alias CustyardWeb.Telemetry`: that shadows the top-level
  # `Telemetry` namespace, so `Telemetry.Metrics.Summary` below would resolve to
  # `CustyardWeb.Telemetry.Metrics.Summary` and silently never match.
  alias Telemetry.Metrics

  @poller_events [
    [:custyard, :conversations, :active],
    [:custyard, :conversations, :by_state]
  ]

  describe "metrics/0 declarations" do
    test "are all Telemetry.Metrics structs" do
      known = [
        Metrics.Counter,
        Metrics.Distribution,
        Metrics.LastValue,
        Metrics.Sum,
        Metrics.Summary
      ]

      for metric <- CustyardWeb.Telemetry.metrics() do
        assert metric.__struct__ in known,
               "not a Telemetry.Metrics struct: #{inspect(metric)}"
      end
    end

    test "declare no duplicate name/type pairs" do
      duplicates =
        CustyardWeb.Telemetry.metrics()
        |> Enum.frequencies_by(&{&1.name, &1.__struct__})
        |> Enum.filter(fn {_key, count} -> count > 1 end)

      assert duplicates == [],
             "a reporter would double-report these: #{inspect(duplicates)}"
    end
  end

  describe "periodic_measurements/0 emissions" do
    test "every event emitted is declared in metrics/0" do
      emitted =
        capture_events(@poller_events, &CustyardWeb.Telemetry.measure_conversation_counts/0)
        |> Enum.map(fn {event, _measurements, _metadata} -> event end)
        |> Enum.uniq()

      declared = CustyardWeb.Telemetry.metrics() |> Enum.map(& &1.event_name) |> MapSet.new()

      for event <- emitted do
        assert MapSet.member?(declared, event),
               "#{inspect(event)} is emitted every 10s but no metric declares it, " <>
                 "so it queries the database to produce a number nothing can read"
      end

      # Guard the inverse too: a declaration whose event never fires is a chart
      # that will read empty forever.
      assert emitted != [], "the poller emitted nothing at all"
    end

    test "every declared tag and measurement is present in what the emit site sends" do
      events =
        capture_events(@poller_events, &CustyardWeb.Telemetry.measure_conversation_counts/0)

      metrics = CustyardWeb.Telemetry.metrics()

      for {event, measurements, metadata} <- events,
          metric <- Enum.filter(metrics, &(&1.event_name == event)) do
        for tag <- metric.tags do
          assert Map.has_key?(metadata, tag),
                 "#{inspect(metric.name)} declares tag #{inspect(tag)}, absent from " <>
                   "#{inspect(event)} metadata #{inspect(metadata)}"

          refute is_map(Map.fetch!(metadata, tag)),
                 "tag #{inspect(tag)} on #{inspect(metric.name)} is map-valued; " <>
                   "a reporter cannot group by it"
        end

        if is_atom(metric.measurement) do
          assert Map.has_key?(measurements, metric.measurement),
                 "#{inspect(metric.name)} measures #{inspect(metric.measurement)}, " <>
                   "absent from #{inspect(event)} measurements #{inspect(measurements)}"
        end
      end
    end

    test "reports zero for an empty state rather than omitting it" do
      # `group_by` returns no row for a state with no conversations. If those
      # states were simply skipped, a last_value gauge would keep reporting the
      # count from the last sample where the state was non-empty, and a drained
      # queue would read as full.
      by_state = poll_by_state()

      expected = Enum.reject(Conversation.states(), &(&1 == :resolved))

      assert Enum.sort(Map.keys(by_state)) == Enum.sort(expected)
      assert Map.values(by_state) |> Enum.all?(&(&1 == 0))
    end

    test "counts a conversation under its own state and leaves the others at zero" do
      insert_conversation(state: :waiting)

      by_state = poll_by_state()

      assert by_state[:waiting] == 1

      for {state, count} <- Map.delete(by_state, :waiting) do
        assert count == 0, "#{state} should be empty, got #{count}"
      end
    end

    test "the total matches the sum of the per-state breakdown" do
      insert_conversation(state: :new)
      insert_conversation(state: :waiting)
      # :resolved is excluded from the queue-depth measurement entirely.
      insert_conversation(state: :resolved)

      events =
        capture_events(@poller_events, &CustyardWeb.Telemetry.measure_conversation_counts/0)

      [{_event, %{count: total}, _metadata}] =
        Enum.filter(events, fn {event, _m, _md} ->
          event == [:custyard, :conversations, :active]
        end)

      assert total == 2
      assert total == events |> by_state_map() |> Map.values() |> Enum.sum()
    end
  end

  defp poll_by_state do
    capture_events(@poller_events, &CustyardWeb.Telemetry.measure_conversation_counts/0)
    |> by_state_map()
  end

  defp by_state_map(events) do
    for {[:custyard, :conversations, :by_state], %{count: count}, %{state: state}} <- events,
        into: %{},
        do: {state, count}
  end

  # Collects every emission of `events` during `fun`, as {event, measurements, metadata}.
  defp capture_events(events, fun) do
    parent = self()
    handler_id = {__MODULE__, events, System.unique_integer()}

    :telemetry.attach_many(
      handler_id,
      events,
      fn event, measurements, metadata, _config ->
        send(parent, {handler_id, event, measurements, metadata})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    drain_events(handler_id, [])
  end

  defp drain_events(handler_id, acc) do
    receive do
      {^handler_id, event, measurements, metadata} ->
        drain_events(handler_id, [{event, measurements, metadata} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end
end
