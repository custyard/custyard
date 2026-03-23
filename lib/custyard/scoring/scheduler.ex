defmodule Custyard.Scoring.Scheduler do
  @moduledoc """
  Periodically recalculates attention scores for all active conversations.

  Idle time components of the scoring formula go stale without periodic
  recalculation, so this GenServer invokes `Recalculator.recalculate_all/0`
  on a fixed interval.
  """

  use GenServer
  require Logger

  alias Custyard.Scoring.Recalculator

  @interval :timer.minutes(5)

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_args) do
    schedule_recalculate()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:recalculate, state) do
    run_recalculate()
    schedule_recalculate()
    {:noreply, state}
  end

  defp schedule_recalculate do
    Process.send_after(self(), :recalculate, @interval)
  end

  defp run_recalculate do
    Logger.info("Scoring.Scheduler: starting recalculation")

    case safe_recalculate() do
      :ok ->
        Logger.info("Scoring.Scheduler: recalculation complete")

      {:error, reason} ->
        Logger.error("Scoring.Scheduler: recalculation failed: #{inspect(reason)}")
    end
  end

  defp safe_recalculate do
    Recalculator.recalculate_all()
    :ok
  rescue
    e -> {:error, e}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
