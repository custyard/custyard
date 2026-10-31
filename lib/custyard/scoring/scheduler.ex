defmodule Custyard.Scoring.Scheduler do
  @moduledoc """
  Periodically recalculates attention scores for all active conversations.

  Idle time components of the scoring formula go stale without periodic
  recalculation, so this GenServer invokes `Recalculator.recalculate_all/0`
  on a fixed interval.

  Also runs dormancy checks to transition stale waiting conversations,
  neglect notification checks, and the inbound channel quiet check
  (`Custyard.InboundChannels.check_quiet_channels/1`).
  """

  use GenServer
  require Custyard.Log, as: Log

  alias Custyard.Conversations.DormancyChecker
  alias Custyard.Email.LMTPServer
  alias Custyard.InboundChannels
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
    Task.start(Log.task(fn -> run_recalculate_task() end))
    Task.start(Log.task(fn -> run_dormancy_check() end))
    Task.start(Log.task(fn -> run_neglect_notifications() end))
    Task.start(Log.task(fn -> run_quiet_channel_check() end))
    Task.start(Log.task(fn -> run_lmtp_cleanup() end))
  end

  defp run_recalculate_task do
    Log.info(:scoring_recalculation_started)

    case safe_recalculate() do
      {:ok, count} ->
        Log.info(:scoring_recalculation_completed, count: count)

      {:error, reason} ->
        Log.error(:scoring_recalculation_failed, Log.failure(reason))
    end
  end

  defp run_dormancy_check do
    case safe_dormancy_check() do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Log.info(:dormancy_check_completed, count: count)

      {:error, reason} ->
        Log.error(:dormancy_check_failed, Log.failure(reason))
    end
  end

  defp run_neglect_notifications do
    case safe_neglect_check() do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Log.info(:neglect_check_completed, count: count)

      {:error, reason} ->
        Log.error(:neglect_check_failed, Log.failure(reason))
    end
  end

  defp run_quiet_channel_check do
    case safe_quiet_channel_check() do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Log.info(:quiet_channel_check_completed, count: count)

      {:error, reason} ->
        Log.error(:quiet_channel_check_failed, Log.failure(reason))
    end
  end

  defp safe_quiet_channel_check do
    InboundChannels.check_quiet_channels()
  rescue
    e -> {:error, e}
  catch
    kind, reason -> {:error, {kind, reason}}
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

  defp run_lmtp_cleanup do
    case safe_lmtp_cleanup() do
      {:ok, 0} ->
        :ok

      {:ok, count} ->
        Log.debug(:lmtp_rate_limit_cleanup_completed, count: count)

      {:error, reason} ->
        Log.error(:lmtp_rate_limit_cleanup_failed, Log.failure(reason))
    end
  end

  defp safe_lmtp_cleanup do
    count = LMTPServer.cleanup_rate_limits()
    {:ok, count}
  rescue
    e -> {:error, e}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
