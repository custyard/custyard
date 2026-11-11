defmodule Custyard.Boot.MonitorTest do
  # Writes Custyard.Boot.State (:persistent_term): sequential.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Custyard.Boot.{Env, Monitor, State}

  setup do
    State.reset()
    on_exit(fn -> State.reset() end)
    %{env: Env.read(%{}, config_env: :prod)}
  end

  # A probe that answers from a scripted list, then keeps returning the last
  # answer, telling the test about each call.
  defp scripted_probe(answers) do
    test = self()
    {:ok, agent} = Agent.start_link(fn -> answers end)

    fn _env ->
      answer =
        Agent.get_and_update(agent, fn
          [only] -> {only, [only]}
          [head | rest] -> {head, rest}
        end)

      send(test, {:probed, answer})
      answer
    end
  end

  defp start(env, probe, opts \\ []) do
    test = self()

    start_supervised!(
      {Monitor,
       [
         env: env,
         every: 5,
         probe: probe,
         stop: fn code -> send(test, {:stopped, code}) end,
         name: :"monitor_#{System.unique_integer([:positive])}"
       ] ++ opts}
    )
  end

  test "exits 1 after three consecutive successes, resetting on a failure", %{env: env} do
    failure = {:error, :unreachable, "nope"}

    log =
      capture_log(fn ->
        start(env, scripted_probe([:ok, :ok, failure, :ok, :ok, :ok]))

        assert_receive {:probed, :ok}
        assert_receive {:probed, :ok}
        assert_receive {:probed, ^failure}
        refute_received {:stopped, _}
        assert_receive {:probed, :ok}
        assert_receive {:probed, :ok}
        assert_receive {:probed, :ok}
        assert_receive {:stopped, 1}
      end)

    assert log =~ "boot_database_recovered"
  end

  test "stops only once", %{env: env} do
    capture_log(fn ->
      start(env, scripted_probe([:ok]), successes: 2)
      assert_receive {:stopped, 1}
      refute_receive {:stopped, _}, 30
    end)
  end

  test "never probes after a migration failure", %{env: env} do
    State.update(fn state ->
      %{state | database: %{state.database | status: :error, category: :migration_failed}}
    end)

    pid = start(env, scripted_probe([:ok]))
    refute_receive {:probed, _}, 30
    refute_received {:stopped, _}
    assert Process.alive?(pid)
  end

  test "defaults the interval to the state's retry period", %{env: env} do
    {:ok, pid} =
      Monitor.start_link(env: env, name: nil, probe: fn _ -> :ok end, stop: fn _ -> :ok end)

    assert :sys.get_state(pid).every == State.get().database.retry_every_ms
    GenServer.stop(pid)
  end
end
