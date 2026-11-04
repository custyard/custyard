defmodule Custyard.Application do
  @moduledoc """
  Starts one of four supervision tree shapes, by boot verdict
  (docs/backlog/1103-first-run-experience.md).

  In production `config/runtime.exs` stores the parsed environment as
  `:boot_env`.

    * `:unconfigured` starts only the telemetry and the endpoint, which
      serves the doctor card.
    * `:configured` starts the same two children first, in mode `:starting`,
      so `/api/health/live` answers while the database is probed
      (`Custyard.Boot.Probe`) and migrations run
      (`Custyard.Boot.FirstRun.migrate/2`). Over libSQL HTTP against a cold
      database, migrations can outlast a platform's start grace; a container
      killed mid-migration restarts into a half-applied schema.
    * When the probe and migrations succeed, the remaining children are added
      to the running supervisor one at a time, in the order
      `deferred_children/1` lists them. `Custyard.Boot.FirstRun`, which comes
      after the Repo, PubSub and the HTTP client, moves the mode out of
      `:starting` as its first step and then finishes the operator and mail
      steps.
    * When they fail, `Custyard.Boot.Monitor` is added instead; it exits the
      VM once the database answers.

  In production the Endpoint therefore starts before the Repo and PubSub, and
  is stopped after them on shutdown. `CustyardWeb.Plugs.BootGate` blocks
  everything but health and static assets while the mode is `:starting`, so
  no request reaches the Repo or PubSub before they exist.

  Development and test have no `:boot_env`: they start the full tree in one
  `Supervisor.start_link`, in the order they always have (Endpoint after the
  Repo and PubSub), and development creates its placeholder operator.
  """

  use Application

  require Custyard.Log, as: Log

  alias Custyard.Acknowledgments.Config, as: AcknowledgmentsConfig
  alias Custyard.Acknowledgments.Consumer, as: AcknowledgmentsConsumer
  alias Custyard.Boot.{Build, Console, Env, FirstRun, Monitor, Probe, Report, State}

  @default_operator_email "admin@custyard.local"

  @impl true
  def start(_type, _args) do
    Custyard.Log.install!()

    # Report crashed-process and LiveView exceptions to Sentry. These never pass
    # through Sentry.PlugCapture (they run off the request path), so the logger
    # handler is what captures them. Only added when a DSN is configured, so
    # dev/test are unaffected.
    maybe_add_sentry_logger_handler()

    case Application.get_env(:custyard, :boot_env) do
      %Env{} = env -> boot(env, DateTime.utc_now())
      nil -> start_without_verdict()
    end
  end

  # Dev and test: today's tree, and the dev operator after it is up.
  defp start_without_verdict do
    result = supervise(full_children([]))

    if Application.get_env(:custyard, :env) == :dev do
      Task.start(Log.task(fn -> setup_dev_operator() end))
    end

    result
  end

  defp boot(%Env{verdict: :unconfigured} = env, booted_at) do
    State.put(%State{mode: :unconfigured, env: env, booted_at: booted_at})
    print_report(env, booted_at)
    Log.warning(:boot_unconfigured, count: length(env.problems))
    Log.info(:boot_mode_decided, boot_mode: :unconfigured)
    supervise(doctor_children([]))
  end

  defp boot(%Env{verdict: :configured} = env, booted_at) do
    State.put(%State{mode: :starting, env: env, booted_at: booted_at})
    print_report(env, booted_at)
    Log.info(:boot_mode_decided, boot_mode: :starting)

    # Telemetry and the Endpoint come up first so liveness answers while the
    # probe and migrations run; the BootGate serves the starting card.
    with {:ok, sup} <- supervise(doctor_children([])) do
      case probe_and_migrate(env) do
        {:ok, schema} ->
          # The mode stays :starting until FirstRun runs, which is after the
          # Repo, PubSub and the HTTP client in deferred_children/1; publishing
          # it here would let a request through to children not yet started.
          start_children(sup, deferred_children(first_run: [env: env, schema: schema]))

        {:error, category, detail} ->
          State.update(fn state ->
            database = %{state.database | status: :error, category: category, detail: detail}
            %{state | mode: :database_unavailable, database: database}
          end)

          Log.info(:boot_mode_decided,
            boot_mode: :database_unavailable,
            database_category: category
          )

          start_children(sup, [{Monitor, env: env}])
      end
    end
  end

  defp probe_and_migrate(env) do
    with :ok <- Probe.run(env) do
      migrate()
    end
  end

  # Adds children to the running supervisor in order. A child that cannot
  # start fails the application start, as it would have under start_link.
  defp start_children(sup, children) do
    Enum.reduce_while(children, {:ok, sup}, fn child, acc ->
      spec = Supervisor.child_spec(child, [])

      case Supervisor.start_child(sup, spec) do
        {:ok, _} -> {:cont, acc}
        {:error, reason} -> {:halt, {:error, {:boot_child_failed, spec.id, reason}}}
      end
    end)
  end

  # Migrations run here, synchronously, on a temporary Repo: see the
  # moduledoc of Custyard.Boot.FirstRun for why not an Ecto.Migrator child.
  defp migrate do
    case FirstRun.migrate(Custyard.Repo, skip: System.get_env("SKIP_MIGRATIONS") == "true") do
      {:ok, schema} ->
        {:ok, schema}

      {:error, detail, reason} ->
        Log.error(:boot_migration_failed, Log.failure(reason))
        {:error, :migration_failed, detail}
    end
  end

  defp print_report(env, booted_at) do
    Console.puts(Report.to_text(env, build: Build.describe(), booted_at: booted_at))
  end

  defp supervise(children) do
    Supervisor.start_link(children, strategy: :one_for_one, name: Custyard.Supervisor)
  end

  defp doctor_children(extra) do
    early_children() ++ extra
  end

  # Dev and test: the whole tree in one start_link, Endpoint after the Repo
  # and PubSub as it always was.
  defp full_children(opts) do
    [CustyardWeb.Telemetry | core_children(opts)]
    |> Kernel.++([CustyardWeb.Endpoint])
    |> add_optional_children()
  end

  @doc false
  # What a production `:configured` boot starts before the probe: enough to
  # answer liveness and serve the starting card.
  @spec early_children() :: [Supervisor.child_spec() | module]
  def early_children, do: [CustyardWeb.Telemetry, CustyardWeb.Endpoint]

  @doc false
  # Everything else, added after the probe and migrations succeed. Same order
  # as `full_children/1` minus the two early children.
  @spec deferred_children(keyword) :: [Supervisor.child_spec() | {module, term} | module]
  def deferred_children(opts), do: core_children(opts) |> add_optional_children()

  defp core_children(opts) do
    [
      Custyard.Repo,
      {DNSCluster, query: Application.get_env(:custyard, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Custyard.PubSub},
      {Finch, name: Custyard.Finch},
      # Sliding-window rate limiter (owns its ETS table, sweeps stale entries)
      {Custyard.RateLimit, []},
      # Task supervisor for async webhook purposes (enrichment, notification, audit)
      {Task.Supervisor, name: Custyard.TaskSupervisor, max_children: 100}
    ]
    |> maybe_add_first_run(opts[:first_run])
  end

  defp add_optional_children(children) do
    children
    |> maybe_add_scheduler()
    |> maybe_add_outbound_queue()
    |> maybe_add_acknowledgment_consumer()
    |> maybe_add_intake_sweeps()
    |> maybe_add_lmtp_server()
    |> maybe_add_imap_pollers()
  end

  # After Finch (API mail adapters send through it), before the workers.
  defp maybe_add_first_run(children, nil), do: children
  defp maybe_add_first_run(children, opts), do: children ++ [{FirstRun, opts}]

  # Attach Sentry.LoggerHandler when (and only when) a DSN is configured.
  # :logger.add_handler/3 signals failure by return value, not by raising, so we
  # match on it: an already-registered handler (config reload/restart) is
  # expected and fine; any other error is logged rather than silently dropped.
  defp maybe_add_sentry_logger_handler do
    if Application.get_env(:sentry, :dsn) do
      case :logger.add_handler(
             :custyard_sentry_handler,
             Sentry.LoggerHandler,
             Custyard.Sentry.logger_handler_config()
           ) do
        :ok ->
          :ok

        {:error, {:already_exist, _}} ->
          :ok

        {:error, reason} ->
          Log.warning(:sentry_handler_attach_failed, Log.failure(reason))
      end
    end
  end

  defp maybe_add_scheduler(children) do
    if Application.get_env(:custyard, :start_scheduler, true) do
      children ++ [Custyard.Scoring.Scheduler]
    else
      children
    end
  end

  defp maybe_add_outbound_queue(children) do
    if Application.get_env(:custyard, :start_outbound_queue, true) do
      children ++ [Custyard.Email.OutboundQueue]
    else
      children
    end
  end

  # Decided here rather than in config/runtime.exs, so release commands such as
  # bin/operator still boot when acknowledgment configuration is incomplete.
  # Incomplete or invalid configuration raises (without values) and the
  # application refuses to start. The consumer loads its configuration itself:
  # a child spec carrying the URL would put the password in supervisor reports.
  defp maybe_add_acknowledgment_consumer(children) do
    case AcknowledgmentsConfig.startup() do
      :enabled -> children ++ [AcknowledgmentsConsumer]
      _ -> children
    end
  end

  # Public-intake background sweeps (expired slug claims, retention bounds).
  # Flagged off in config/test.exs — tests drive the sweep functions
  # directly with an injected clock or explicit options.
  defp maybe_add_intake_sweeps(children) do
    if Application.get_env(:custyard, :start_intake_sweeps, true) do
      children ++ [Custyard.Slugs.ClaimExpiry, Custyard.Conversations.RetentionSweep]
    else
      children
    end
  end

  defp maybe_add_lmtp_server(children) do
    lmtp_config = Application.get_env(:custyard, :lmtp, [])

    if Keyword.get(lmtp_config, :enabled, false) do
      port = Keyword.get(lmtp_config, :port, 2024)
      hostname = Keyword.get(lmtp_config, :hostname, "localhost")
      tls_opts = Keyword.get(lmtp_config, :tls, [])
      max_received_count = Keyword.get(lmtp_config, :max_received_count, 3)
      # Memory-bounded connection limits (each connection can buffer up to 25MB)
      max_connections = Keyword.get(lmtp_config, :max_connections, 100)
      num_acceptors = Keyword.get(lmtp_config, :num_acceptors, 5)

      opts = [
        port: port,
        hostname: hostname,
        tls: tls_opts,
        max_received_count: max_received_count,
        max_connections: max_connections,
        num_acceptors: num_acceptors
      ]

      children ++ [{Custyard.Email.LMTPServer, opts}]
    else
      children
    end
  end

  # IMAP channels replaced the global poller (spec-inbound-channels D8). A
  # deployment that still sets IMAP_ENABLED is reported by Custyard.Boot.Env;
  # here it only means no pollers start.
  defp maybe_add_imap_pollers(children) do
    cond do
      Application.get_env(:custyard, :legacy_imap_enabled, false) ->
        children

      Application.get_env(:custyard, :start_imap_pollers, true) ->
        children ++ [Custyard.Email.ImapPollers]

      true ->
        children
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    CustyardWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp setup_dev_operator do
    # Wait for Repo with exponential backoff instead of fixed sleep
    wait_for_repo(5, 100)
    do_setup_dev_operator()
  rescue
    e ->
      Log.warning(:dev_operator_setup_failed, Log.failure(e))
  end

  # Poll for Repo availability with exponential backoff
  # max_attempts=5, initial_delay_ms=100 gives delays: 100, 200, 400, 800, 1600 = ~3s total
  defp wait_for_repo(0, _delay_ms), do: :ok

  defp wait_for_repo(attempts_remaining, delay_ms) do
    if repo_ready?() do
      :ok
    else
      Process.sleep(delay_ms)
      wait_for_repo(attempts_remaining - 1, delay_ms * 2)
    end
  end

  defp repo_ready? do
    alias Custyard.Repo
    # Try a simple query - if it succeeds, Repo is ready
    Repo.query("SELECT 1")
    true
  rescue
    _ -> false
  end

  defp do_setup_dev_operator do
    case Custyard.OperatorAccounts.create_operator(@default_operator_email,
           via: "boot",
           allow_placeholder: true
         ) do
      {:created, operator} ->
        Log.info(:dev_operator_created, operator_id: operator.id, mode: :development)

      {:exists, operator} ->
        Log.debug(:dev_operator_exists, operator_id: operator.id, mode: :development)

      {:error, reason} ->
        Log.warning(:dev_operator_setup_failed, Log.failure(reason))
    end
  end
end
