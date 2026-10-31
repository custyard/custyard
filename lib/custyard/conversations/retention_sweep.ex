defmodule Custyard.Conversations.RetentionSweep do
  @moduledoc """
  Daily sweep enforcing the documented retention bounds.

  `Conversations.run_cleanup/1` implements the conversation bounds — 90 days
  for resolved conversations, 365 for resolved public-intake ones (spec: NFR
  Retention), plus orphaned contacts and tasks — and was fully tested but
  had no caller, so nothing ever ran it. Prospect emails accumulated
  indefinitely, contradicting the stated policy.

  `InboundChannels.sweep_expired/0` runs in the same sweep for the inbound
  channel bounds (spec-inbound-channels, Privacy and compliance: Retention):
  rejection log rows after 14 days, verification captures after 24 hours,
  rotated tokens at the end of their grace period. It is skipped on a dry
  run, which reports zero for its keys.

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

  require Custyard.Log, as: Log

  alias Custyard.{Conversations, InboundChannels}

  @interval :timer.hours(24)
  @zero_counts %{
    resolved_conversations: 0,
    orphaned_contacts: 0,
    orphaned_tasks: 0,
    channel_rejections: 0,
    channel_verifications: 0,
    channel_tokens: 0,
    attachment_files: 0
  }

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
  `run_cleanup/1` returns plus `channel_rejections`, `channel_verifications`
  and `channel_tokens` from `InboundChannels.sweep_expired/0`, or a zeroed
  map when the sweep fails — a failure is logged and the next interval
  retries.
  """
  def sweep(opts \\ []) do
    Log.operation([], fn -> do_sweep(opts) end)
  end

  defp do_sweep(opts) do
    counts =
      opts
      |> Conversations.run_cleanup()
      |> Map.merge(channel_counts(opts))

    if Enum.any?(counts, fn {_key, count} -> count > 0 end) do
      Log.info(:retention_sweep_completed, Map.to_list(counts))
    end

    counts
  rescue
    e ->
      Log.error(:retention_sweep_failed, Log.failure(e))
      @zero_counts
  end

  defp channel_counts(opts) do
    if Keyword.get(opts, :dry_run, false) do
      Map.take(@zero_counts, [
        :channel_rejections,
        :channel_verifications,
        :channel_tokens,
        :attachment_files
      ])
    else
      %{rejections: rejections, verifications: verifications, tokens: tokens} =
        InboundChannels.sweep_expired()

      %{
        channel_rejections: rejections,
        channel_verifications: verifications,
        channel_tokens: tokens,
        # Files whose attachment rows went with their swept conversations.
        attachment_files: Custyard.Attachments.sweep_orphan_files()
      }
    end
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @interval)
  end
end
