defmodule Custyard.Slugs.ClaimExpiry do
  @moduledoc """
  Hourly sweep deleting expired, unconfirmed slug claims.

  Lazy expiry inside `Custyard.Slugs.claim/3` already handles the
  claim-an-expired-slug race; this sweep handles the rest, so the registry
  never accumulates dead rows and `available` stays "no row" in practice,
  not just through the lazy path.

  Supervised behind `config :custyard, :start_intake_sweeps` (off in test —
  `sweep/1` takes an injectable clock and is tested directly). Follows the
  DormancyChecker/Scheduler pattern: a plain interval GenServer whose work
  function is public and deterministic.
  """

  use GenServer

  require Custyard.Log, as: Log

  alias Custyard.Slugs

  @interval :timer.hours(1)

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
    _count = sweep()
    schedule_sweep()
    {:noreply, state}
  end

  @doc """
  Delete expired claimed rows as of `now` (injectable clock; defaults to
  `DateTime.utc_now/0`). Returns the count deleted. Never raises — a sweep
  failure is logged and the next interval retries.
  """
  def sweep(now \\ DateTime.utc_now()) do
    Log.operation([], fn -> do_sweep(now) end)
  end

  defp do_sweep(now) do
    count = Slugs.delete_expired_claims(now)

    if count > 0 do
      Log.info(:slug_claim_expiry_completed, count: count)
    end

    count
  rescue
    e ->
      Log.error(:slug_claim_expiry_failed, Log.failure(e))
      0
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep, @interval)
  end
end
