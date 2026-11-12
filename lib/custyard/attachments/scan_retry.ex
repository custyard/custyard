defmodule Custyard.Attachments.ScanRetry do
  @moduledoc """
  Retries failed attachment malware scans every minute
  (`Custyard.Attachments.retry_failed_scans/1`).

  A scanner that scales to zero starts on the connection of the first scan
  after it went idle, and that scan times out long before the scanner is
  ready. The attachment stays quarantined with a failed scan, and nothing
  else rescans it: a delivery replay reuses fetched attachments. This
  process retries such scans on a backoff for a day after the attachment
  was stored; after that an administrator's rescan or
  `Custyard.Release.scan_attachments/0` remains.

  Started only when a scanner is configured, and kept out of the test
  environment by `config :custyard, :start_attachment_scan_retry`: tests
  call `retry_failed_scans/1` directly and start this process themselves.
  Follows the `Custyard.Slugs.ClaimExpiry` pattern: a plain interval
  GenServer whose first tick waits one interval. A tick that raises is
  logged and the next one runs as scheduled. Options:

    * `:interval` - milliseconds between ticks (default: the
      `:attachment_scan_retry_interval` setting, else one minute)
    * `:retry` - the zero-arity work function (default:
      `Custyard.Attachments.retry_failed_scans/0`)
  """

  use GenServer

  require Custyard.Log, as: Log

  @interval :timer.minutes(1)
  @no_scans %{clean: 0, infected: 0, error: 0, pending: 0}

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    state = %{
      interval:
        Keyword.get_lazy(opts, :interval, fn ->
          Application.get_env(:custyard, :attachment_scan_retry_interval, @interval)
        end),
      retry: Keyword.get(opts, :retry, &Custyard.Attachments.retry_failed_scans/0)
    }

    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_info(:retry, state) do
    _counts = Log.operation([], fn -> run(state.retry) end)
    schedule(state)
    {:noreply, state}
  end

  defp run(retry) do
    counts = retry.()
    rescanned = counts |> Map.values() |> Enum.sum()

    if rescanned > 0 do
      Log.info(:attachment_scan_retry_completed,
        count: rescanned,
        clean_scans: counts.clean,
        infected_scans: counts.infected,
        failed_scans: counts.error,
        pending_scans: counts.pending
      )
    end

    counts
  rescue
    e ->
      Log.error(:attachment_scan_retry_failed, Log.failure(e))
      @no_scans
  catch
    kind, reason ->
      Log.error(:attachment_scan_retry_failed, Log.failure({kind, reason}))
      @no_scans
  end

  defp schedule(%{interval: interval}), do: Process.send_after(self(), :retry, interval)
end
