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
  > Modules that need an operator to actually see something log alongside the
  > emit. Attaching a reporter is tracked separately; it predates the intake
  > work and affects the LMTP, webhook, scoring and sender-matching metrics
  > equally.
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
        description: "Single conversation score calculation duration"
      ),
      summary("custyard.scoring.batch.stop.duration",
        unit: {:native, :millisecond},
        description: "Batch score recalculation duration"
      ),
      last_value("custyard.scoring.batch.count",
        description: "Number of conversations in last batch recalculation"
      ),

      # Sender Matching Metrics (events to be emitted by SenderMatching)
      summary("custyard.sender_matching.process.stop.duration",
        unit: {:native, :millisecond},
        tags: [:result],
        description: "Sender matching and conversation creation duration"
      ),
      counter("custyard.conversation.created.count",
        description: "Total conversations created"
      ),
      counter("custyard.message.created.count",
        tags: [:source],
        description: "Total messages created by source"
      ),

      # Public Intake Metrics (events emitted by IntakeController and
      # Plugs.PublicRateLimit). NOTE: nothing consumes this list yet — see the
      # moduledoc. These declarations exist so a reporter picks them up the day
      # one is attached; until then the Logger lines at each emit site are the
      # only readable signal.
      counter("custyard.intake.submission.count",
        tags: [:mode, :email_captured, :receipt],
        description: "Accepted public intake submissions"
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
      # Periodic measurement for active conversation count
      {__MODULE__, :measure_conversation_counts, []}
    ]
  end

  @doc false
  def measure_conversation_counts do
    # Import Ecto.Query for this measurement function
    import Ecto.Query, only: [from: 2]

    try do
      # Count active (non-resolved) conversations by state
      counts =
        from(c in Custyard.Conversation,
          where: c.state != :resolved,
          group_by: c.state,
          select: {c.state, count(c.id)}
        )
        |> Custyard.Repo.all()
        |> Map.new()

      total = Enum.sum(Map.values(counts))

      :telemetry.execute(
        [:custyard, :conversations, :active],
        %{count: total},
        %{by_state: counts}
      )
    rescue
      # Don't crash periodic measurement if repo is unavailable
      _ -> :ok
    end
  end
end
