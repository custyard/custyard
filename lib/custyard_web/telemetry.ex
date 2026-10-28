defmodule CustyardWeb.Telemetry do
  @moduledoc """
  Telemetry supervisor and metric declarations.

  > **`metrics/0` currently has no consumer.** The supervision tree below
  > starts `:telemetry_poller` only — there is no `Telemetry.Metrics` reporter
  > child, and the LiveDashboard route in `router.ex` is commented out with
  > `phoenix_live_dashboard` not in `mix.exs`. Every metric declared here is
  > therefore inert: the underlying `:telemetry` events do fire, but nothing
  > aggregates or displays them.
  >
  > Modules that need a staff to actually see something log alongside the
  > emit. Attaching a reporter is tracked in custyard/custyard#11; it predates
  > the intake work and affects the LMTP, webhook, scoring and sender-matching
  > metrics equally.
  """

  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.mount.start.system_time",
        tags: [:view],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.mount.stop.duration",
        tags: [:view],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.mount.exception.duration",
        tags: [:view],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.handle_params.start.system_time",
        tags: [:view],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.handle_params.stop.duration",
        tags: [:view],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.handle_params.exception.duration",
        tags: [:view],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.handle_event.start.system_time",
        tags: [:view, :event],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.handle_event.stop.duration",
        tags: [:view, :event],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.live_view.handle_event.exception.duration",
        tags: [:view, :event],
        unit: {:native, :millisecond}
      ),
      summary("custyard.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("custyard.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("custyard.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("custyard.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("custyard.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io"),

      # Queue depth, sampled by periodic_measurements/0 every 10s.
      last_value("custyard.threads.active.count",
        description: "Open threads — every state but :resolved"
      ),
      last_value("custyard.threads.by_state.count",
        tags: [:state],
        description: "Open threads per state, the queue-depth breakdown"
      ),

      # LMTP Server Metrics (events emitted by LMTPServer)
      counter("custyard.lmtp.connection.open.count",
        description: "Total LMTP connections opened"
      ),
      counter("custyard.lmtp.connection.close.count",
        description: "Total LMTP connections closed"
      ),
      counter("custyard.lmtp.connection.rejected.count",
        tags: [:reason],
        description: "LMTP connections rejected (IP not allowed, etc)"
      ),
      summary("custyard.lmtp.email.stop.duration",
        unit: {:native, :millisecond},
        tags: [:result],
        description: "Email processing duration in LMTP pipeline"
      ),
      counter("custyard.lmtp.rate_limit.exceeded.count",
        tags: [:limit_type],
        description: "Rate limit exceeded events by type"
      ),

      # Webhook Pipeline Metrics (events to be emitted by Dispatcher)
      summary("custyard.webhook.dispatch.stop.duration",
        unit: {:native, :millisecond},
        tags: [:adapter, :result],
        description: "Webhook processing duration by adapter"
      ),
      counter("custyard.webhook.dispatch.exception.count",
        tags: [:adapter, :error_type],
        description: "Webhook processing exceptions"
      ),

      # Scoring System Metrics (events to be emitted by Scoring)
      summary("custyard.scoring.calculate.stop.duration",
        unit: {:native, :millisecond},
        description: "Single thread score calculation duration"
      ),
      summary("custyard.scoring.batch.stop.duration",
        unit: {:native, :millisecond},
        description: "Batch score recalculation duration"
      ),
      last_value("custyard.scoring.batch.count",
        description: "Number of threads in last batch recalculation"
      ),

      # Sender Matching Metrics (events to be emitted by SenderMatching)
      summary("custyard.sender_matching.process.stop.duration",
        unit: {:native, :millisecond},
        tags: [:result],
        description: "Sender matching and thread creation duration"
      ),
      counter("custyard.thread.created.count",
        description: "Total threads created"
      ),
      counter("custyard.message.created.count",
        tags: [:source],
        description: "Total messages created by source"
      ),

      # Public Intake Metrics (events emitted by IntakeController and
      # Plugs.PublicRateLimit). NOTE: nothing consumes this list yet — see the
      # moduledoc and custyard/custyard#11. These declarations exist so a
      # reporter picks them up the day one is attached; until then the Logger
      # lines at each emit site are the only readable signal.
      counter("custyard.intake.submission.count",
        tags: [:mode, :email_captured, :receipt],
        description: "Accepted public intake submissions"
      ),
      counter("custyard.intake.submission_rejected.count",
        tags: [:mode],
        description:
          "Submissions the database refused. A server-side loss: the prospect saw a generic failure and left"
      ),
      counter("custyard.intake.unknown_source.count",
        tags: [:reason],
        description:
          "Intake requests for a key with no enabled source. :unknown_key is a bad or stale URL; :disabled_mid_submission means a source went away between page load and POST, losing a real submission"
      ),
      counter("custyard.public_rate_limit.exceeded.count",
        tags: [:bucket],
        description: "Requests rejected by the public per-IP rate limiter"
      )
    ]
  end

  defp periodic_measurements do
    [
      # Periodic measurement for active thread count
      {__MODULE__, :measure_thread_counts, []}
    ]
  end

  @doc false
  def measure_thread_counts do
    # Import Ecto.Query for this measurement function
    import Ecto.Query, only: [from: 2]

    try do
      # Count active (non-resolved) threads by state
      counts =
        from(c in Custyard.Thread,
          where: c.state != :resolved,
          group_by: c.state,
          select: {c.state, count(c.id)}
        )
        |> Custyard.Repo.all()
        |> Map.new()

      total = Enum.sum(Map.values(counts))

      :telemetry.execute([:custyard, :threads, :active], %{count: total}, %{})

      # The breakdown goes out as one event per state with `state` as a tag,
      # rather than riding along as a map in the metadata: a map-valued tag is
      # not something a reporter can group by.
      #
      # Zero-filled from Thread.states/0 because `group_by` returns no row
      # for a state with no threads. Emitting only the states present would
      # leave a `last_value` gauge reporting the stale count from the last sample
      # where that state was non-empty — a drained queue would read as full.
      for state <- Custyard.Thread.states(), state != :resolved do
        :telemetry.execute(
          [:custyard, :threads, :by_state],
          %{count: Map.get(counts, state, 0)},
          %{state: state}
        )
      end
    rescue
      # Don't crash periodic measurement if repo is unavailable
      _ -> :ok
    end
  end
end
