defmodule Custyard.RateLimit do
  @moduledoc """
  Generic sliding-window rate limiter backed by a named ETS table.

  The GenServer owns the table and runs a periodic sweep. Checks
  (`check_rate/2` and `check_rate/5`) serialize through a
  `GenServer.call` to this process so the count-then-insert is atomic:
  callers racing at `limit - 1` cannot all observe an under-limit count
  and over-admit. Serialization is affordable here because every
  configured bucket is low-throughput by construction (single- to
  double-digit limits per window) — and it matters because some buckets
  bound real resources, e.g. `:claim_email_send` caps outbound email
  volume. This deliberately departs from the lock-free
  `LoginRateLimit` precedent, where briefly over-admitting a few failed
  logins is harmless.

  ## Counting Strategy

  Every checked event counts toward the limit — successes and failures
  alike. This is deliberately unlike `CustyardWeb.Plugs.LoginRateLimit`,
  which counts only failed logins: the public intake surfaces are
  anonymous and hammerable, so a flood of "successful" requests is
  exactly what the limiter must bound. Denied requests do not insert an
  event, so being rate limited never extends the deny window.

  ## Bounded Memory

  Each entry stores its own expiry; a periodic sweep in the owning
  GenServer deletes expired entries across all buckets. Periodic sweeping
  was chosen over probabilistic-on-write cleanup because it keeps the
  request path constant-time and — unlike probabilistic cleanup, which
  never runs once traffic stops — guarantees stale entries are reclaimed
  even when a surface goes idle after a burst. `sweep/1` is public so
  tests can exercise it deterministically.

  ## Buckets

  Limits and windows are application config (deliberately not operator
  `Settings` — see docs/design/design-decisions-public-intake.md), read
  from `config :custyard, :rate_limit_buckets` at call time via
  `bucket_config!/1`. Keys are caller-defined terms: client IPs for the
  controller buckets, token hashes for `:resume_reply`, downcased emails
  for `:claim_email_send`.

  ## Single-Node Scope

  Storage is node-local ETS, accepted per the single-instance deployment
  constraint. Running multiple nodes would multiply every limit by the
  node count; this module is the upgrade point — swap the ETS table for
  a shared store (database counters or similar) without touching callers.

  The table dies with the process: a crash or deploy restarts the
  limiter with empty state, resetting every window. Accepted for
  single-node abuse throttling.
  """

  use GenServer

  @table :custyard_rate_limit
  @default_sweep_interval_ms 60_000

  ## Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Checks `key` against the limit configured for `bucket` in
  `config :custyard, :rate_limit_buckets`.

  Raises `ArgumentError` for an unconfigured bucket (a programming or
  configuration error, never request input).
  """
  @spec check_rate(atom(), term()) ::
          {:allow, pos_integer()} | {:deny, pos_integer()}
  def check_rate(bucket, key) do
    {limit, window_ms} = bucket_config!(bucket)
    check_rate(bucket, key, limit, window_ms)
  end

  @doc """
  Sliding-window check: allows the first `limit` events per `key` within
  any trailing `window_ms`, counting every allowed event. `now` defaults
  to `System.monotonic_time(:millisecond)`; injectable (like `sweep/1`)
  so tests can walk the window deterministically.

  Serialized through the owning GenServer so concurrent checks cannot
  over-admit past the limit.

  Returns `{:allow, count}` (count includes this event) or
  `{:deny, retry_after_ms}` where `retry_after_ms` is how long until a
  retry could be allowed.
  """
  @spec check_rate(atom(), term(), integer(), pos_integer(), integer()) ::
          {:allow, pos_integer()} | {:deny, pos_integer()}
  def check_rate(bucket, key, limit, window_ms, now \\ System.monotonic_time(:millisecond))

  def check_rate(_bucket, _key, limit, window_ms, _now) when limit <= 0 do
    {:deny, window_ms}
  end

  def check_rate(bucket, key, limit, window_ms, now) do
    GenServer.call(__MODULE__, {:check_rate, {bucket, key}, limit, window_ms, now})
  end

  @doc """
  Non-counting check: reports whether `key` is currently within the limit
  configured for `bucket` WITHOUT recording an event.

  Lets an early surface honor a budget that another surface owns and
  counts — e.g. `CustyardWeb.Plugs.ResumeCookie` refuses the cookie
  refresh once `ResumeAuth`'s `:resume_mount` budget is exhausted, without
  double-billing the HTTP mount that follows in the same request.

  Reads the ETS table directly (no GenServer round trip): nothing is
  written, so the count-then-insert atomicity that serializes
  `check_rate` does not apply.

  Returns `{:allow, count}` (in-window events so far, may be `0`) or
  `{:deny, retry_after_ms}`.
  """
  @spec peek(atom(), term(), integer()) ::
          {:allow, non_neg_integer()} | {:deny, pos_integer()}
  def peek(bucket, key, now \\ System.monotonic_time(:millisecond)) do
    {limit, window_ms} = bucket_config!(bucket)

    if limit <= 0 do
      {:deny, window_ms}
    else
      window_start = now - window_ms
      timestamps = timestamps_in_window({bucket, key}, window_start)
      count = length(timestamps)

      if count >= limit do
        {:deny, retry_after(timestamps, limit, window_ms, now)}
      else
        {:allow, count}
      end
    end
  end

  @doc """
  Resolves `{limit, window_ms}` for a configured bucket.

  Raises `ArgumentError` when the bucket is not configured.
  """
  @spec bucket_config!(atom()) :: {integer(), pos_integer()}
  def bucket_config!(bucket) when is_atom(bucket) do
    buckets = Application.get_env(:custyard, :rate_limit_buckets, [])

    case Keyword.fetch(buckets, bucket) do
      {:ok, config} ->
        {Keyword.fetch!(config, :limit), Keyword.fetch!(config, :window_ms)}

      :error ->
        raise ArgumentError,
              "unknown rate-limit bucket #{inspect(bucket)}; " <>
                "configure it under `config :custyard, :rate_limit_buckets`"
    end
  end

  @doc """
  Deletes every entry whose window has expired as of `now`
  (`System.monotonic_time(:millisecond)` by default). Returns the number
  of entries deleted. Called periodically by the owning GenServer;
  public so tests can drive it deterministically.

  Serialized through the owning GenServer, like `check_rate/5`, since the
  table is `:protected` and only the owner process may write to it.
  """
  @spec sweep(integer()) :: non_neg_integer()
  def sweep(now \\ System.monotonic_time(:millisecond)) do
    GenServer.call(__MODULE__, {:sweep, now})
  end

  @doc """
  Test helper: clears all rate-limit state.
  """
  @spec reset() :: :ok
  def reset do
    GenServer.call(__MODULE__, :reset)
  end

  ## GenServer callbacks

  @impl true
  def init(opts) do
    table =
      :ets.new(@table, [
        :duplicate_bag,
        :protected,
        :named_table,
        read_concurrency: true,
        write_concurrency: true
      ])

    interval =
      Keyword.get(
        opts,
        :sweep_interval_ms,
        Application.get_env(:custyard, :rate_limit_sweep_interval_ms, @default_sweep_interval_ms)
      )

    schedule_sweep(interval)
    {:ok, %{table: table, sweep_interval_ms: interval}}
  end

  @impl true
  def handle_call({:check_rate, entry_key, limit, window_ms, now}, _from, state) do
    window_start = now - window_ms
    timestamps = timestamps_in_window(entry_key, window_start)
    count = length(timestamps)

    reply =
      if count >= limit do
        {:deny, retry_after(timestamps, limit, window_ms, now)}
      else
        :ets.insert(@table, {entry_key, now, now + window_ms})
        {:allow, count + 1}
      end

    {:reply, reply, state}
  end

  @impl true
  def handle_call({:sweep, now}, _from, state) do
    {:reply, do_sweep(now), state}
  end

  @impl true
  def handle_call(:reset, _from, state) do
    :ets.delete_all_objects(@table)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    # Called from within the owning process, so this bypasses
    # GenServer.call — routing through it here would deadlock.
    do_sweep(System.monotonic_time(:millisecond))
    schedule_sweep(state.sweep_interval_ms)
    {:noreply, state}
  end

  ## Internal

  defp schedule_sweep(interval) do
    Process.send_after(self(), :sweep, interval)
  end

  defp do_sweep(now) do
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:"=<", :"$1", now}], [true]}])
  end

  defp timestamps_in_window(entry_key, window_start) do
    :ets.select(@table, [
      {{entry_key, :"$1", :_}, [{:>, :"$1", window_start}], [:"$1"]}
    ])
  end

  # The retry hint is the time until enough of the oldest in-window
  # events age out for the count to drop below the limit.
  defp retry_after(timestamps, limit, window_ms, now) do
    sorted = Enum.sort(timestamps)
    blocking_ts = Enum.at(sorted, length(sorted) - limit)
    max(blocking_ts + window_ms - now, 1)
  end
end
