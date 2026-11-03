defmodule Custyard.Boot.Monitor do
  @moduledoc """
  Re-probes the database while the app is in the `:database_unavailable`
  doctor mode, and exits the VM once it answers.

  Every `retry_every_ms` (from `Custyard.Boot.State`, 10 s) it calls
  `Custyard.Boot.Probe.run/1`, which also refreshes the attempt count the
  doctor card shows. After three consecutive successes it logs
  `boot_database_recovered` and calls `System.stop(0)`: the platform's
  restart policy then runs the normal boot. No supervision tree is swapped
  at runtime.

  A `:migration_failed` category is never probed and never counts as a
  success: the database answered, the schema did not apply, and nothing
  about waiting changes that. The process stays up so the card is served.

  Options: `env:` (required), `every:` ms, `successes:` needed (default 3),
  `probe:` and `stop:` functions for tests.
  """

  use GenServer

  alias Custyard.Boot.{Probe, State}

  require Custyard.Log, as: Log

  @successes 3

  def start_link(opts) when is_list(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    state = %{
      env: Keyword.fetch!(opts, :env),
      every: Keyword.get(opts, :every, State.get().database.retry_every_ms),
      needed: Keyword.get(opts, :successes, @successes),
      probe: Keyword.get(opts, :probe, &Probe.run/1),
      stop: Keyword.get(opts, :stop, &System.stop/1),
      successes: 0,
      active?: State.get().database.category != :migration_failed
    }

    if state.active?, do: schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:probe, state) do
    state =
      case state.probe.(state.env) do
        :ok -> %{state | successes: state.successes + 1}
        {:error, _category, _detail} -> %{state | successes: 0}
      end

    if state.successes >= state.needed do
      Log.warning(:boot_database_recovered, count: state.successes)
      state.stop.(0)
    else
      schedule(state)
    end

    {:noreply, state}
  end

  defp schedule(state), do: Process.send_after(self(), :probe, state.every)
end
