defmodule Custyard.Scoring.Scheduler do
  @moduledoc """
  Periodically recalculates attention scores for all active conversations.

  Idle time components of the scoring formula go stale without periodic
  recalculation, so this GenServer invokes `Recalculator.recalculate_all/0`
  on a fixed interval.

  Also runs dormancy checks to transition stale waiting conversations
  and neglect notification checks.
  """

  use GenServer
  require Logger

  alias Custyard.Conversations.DormancyChecker
  alias Custyard.Notifications.NeglectChecker
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
    # Run all checks in parallel Tasks to avoid blocking the GenServer
    # This prevents long-running recalculations from blocking dormancy/neglect checks
    Task.start(fn -> run_recalculate_task() end)
    Task.start(fn -> run_dormancy_check() end)
    Task.start(fn -> run_neglect_notifications() end)
  end

  defp run_recalculate_task do
    Logger.info("Scoring.Scheduler: starting recalculation")

    case safe_recalculate() do
      {:ok, count} ->
        Logger.info("Scoring.Scheduler: recalculated #{count} conversations")

      {:error, reason} ->
        Logger.error("Scoring.Scheduler: recalculation failed: #{inspect(reason)}")
    end
  end

  defp run_dormancy_check do
    case safe_dormancy_check() do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Logger.info("Scoring.Scheduler: transitioned #{count} conversations to dormant")

      {:error, reason} ->
        Logger.error("Scoring.Scheduler: dormancy check failed: #{inspect(reason)}")
    end
  end

  defp run_neglect_notifications do
    case safe_neglect_check() do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Logger.info("Scoring.Scheduler: sent #{count} neglect notifications")

      {:error, reason} ->
        Logger.error("Scoring.Scheduler: neglect notification check failed: #{inspect(reason)}")
    end
  end

  defp safe_recalculate do
    count = Recalculator.recalculate_all()
    {:ok, count}
  rescue
    e -> {:error, e}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_dormancy_check do
    count = DormancyChecker.transition_stale_conversations()
    {:ok, count}
  rescue
    e -> {:error, e}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp safe_neglect_check do
    NeglectChecker.check_and_notify()
  rescue
    e -> {:error, e}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
