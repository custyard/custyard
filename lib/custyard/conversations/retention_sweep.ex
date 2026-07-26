defmodule Custyard.Conversations.RetentionSweep do
  @moduledoc """
  Daily sweep enforcing the documented conversation retention bounds.

  `Conversations.run_cleanup/1` implements them — 90 days for resolved
  conversations, 365 for resolved public-intake ones (spec: NFR Retention),
  plus orphaned contacts and tasks — and was fully tested but had no
  caller, so nothing ever ran it. Prospect emails accumulated indefinitely,
  contradicting the stated policy.

  Deliberately its own GenServer rather than a fifth task on
  `Scoring.Scheduler`: that runs every five minutes, and a bulk delete
  belongs nowhere near that cadence. First sweep is delayed rather than run
  at boot, so a crash-loop cannot turn into a delete loop and a deploy does
  not pay for a sweep.

  Supervised behind `config :custyard, :start_intake_sweeps` (off in test —
  `sweep/1` is public and tested directly). Follows the
  `Slugs.ClaimExpiry` pattern: a plain interval GenServer whose work
  function is public, deterministic, and non-raising.
  """

  use GenServer

  require Logger

  alias Custyard.Conversations

  @interval :timer.hours(24)

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_sweep()
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    _counts = sweep()
    schedule_sweep()
    {:noreply, state}
  end

  @doc """
  Delete every row past its retention bound.

  `opts` are passed through to `Conversations.run_cleanup/1`, so a caller
  can pass `dry_run: true` or override either bound. Returns the counts map
  `run_cleanup/1` returns, or a zeroed map when the sweep fails — a failure
  is logged and the next interval retries.
  """
  def sweep(opts \\ []) do
    counts = Conversations.run_cleanup(opts)

    if Enum.any?(counts, fn {_key, count} -> count > 0 end) do
      Logger.info(
        "Conversations.RetentionSweep: deleted " <>
          "#{counts.resolved_conversations} conversations, " <>
          "#{counts.orphaned_contacts} contacts, #{counts.orphaned_tasks} tasks"
      )
    end

    counts
  rescue
    e ->
      Logger.error("Conversations.RetentionSweep: sweep failed: #{inspect(e)}")
      %{resolved_conversations: 0, orphaned_contacts: 0, orphaned_tasks: 0}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @interval)
  end
end
