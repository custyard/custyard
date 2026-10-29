defmodule Custyard.Application do
  @moduledoc false

  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # Debug logging for check_origin config. Uncomment to trace.
    # See: docs/lessons-learned/06-phoenix-check-origin-fly.md, PR #34
    #
    # endpoint_config = Application.get_env(:custyard, CustyardWeb.Endpoint, [])
    # url_config = Keyword.get(endpoint_config, :url, [])
    # check_origin = Keyword.get(endpoint_config, :check_origin)
    # Logger.info(
    #   "[Startup] Endpoint config - url: #{inspect(url_config)}, " <>
    #     "check_origin: #{inspect(check_origin)} (type: #{origin_type(check_origin)})"
    # )

    # Fail before starting the Repo when Fly's persistent volume is missing.
    Custyard.Storage.validate_fly_storage!()

    # Report crashed-process and LiveView exceptions to Sentry. These never pass
    # through Sentry.PlugCapture (they run off the request path), so the logger
    # handler is what captures them. Only added when a DSN is configured, so
    # dev/test are unaffected.
    maybe_add_sentry_logger_handler()

    children =
      [
        CustyardWeb.Telemetry,
        Custyard.Repo,
        {DNSCluster, query: Application.get_env(:custyard, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Custyard.PubSub},
        {Finch, name: Custyard.Finch},
        # Sliding-window rate limiter (owns its ETS table, sweeps stale entries)
        {Custyard.RateLimit, []},
        # Task supervisor for async webhook purposes (enrichment, notification, audit)
        {Task.Supervisor, name: Custyard.TaskSupervisor, max_children: 100},
        CustyardWeb.Endpoint
      ]
      |> maybe_add_scheduler()
      |> maybe_add_outbound_queue()
      |> maybe_add_acknowledgment_consumer()
      |> maybe_add_intake_sweeps()
      |> maybe_add_lmtp_server()
      |> maybe_add_imap_pollers()

    opts = [strategy: :one_for_one, name: Custyard.Supervisor]
    result = Supervisor.start_link(children, opts)

    case {result, Application.get_env(:custyard, :env), System.get_env("INSTANCE_ADMIN_EMAIL")} do
      {{:ok, _}, env, email} when env != :test and is_binary(email) and email != "" ->
        case Custyard.InstanceAdmins.create_admin(email) do
          {status, _admin} when status in [:created, :exists] ->
            :ok

          {:error, changeset} ->
            raise "Invalid INSTANCE_ADMIN_EMAIL: #{inspect(changeset.errors)}"
        end

      _ ->
        :ok
    end

    result
  end

  # Attach Sentry.LoggerHandler when (and only when) a DSN is configured.
  # :logger.add_handler/3 signals failure by return value, not by raising, so we
  # match on it: an already-registered handler (config reload/restart) is
  # expected and fine; any other error is logged rather than silently dropped.
  defp maybe_add_sentry_logger_handler do
    if Application.get_env(:sentry, :dsn) do
      case :logger.add_handler(:custyard_sentry_handler, Sentry.LoggerHandler, %{
             config: %{metadata: [:file, :line]}
           }) do
        :ok ->
          :ok

        {:error, {:already_exist, _}} ->
          :ok

        {:error, reason} ->
          Logger.warning("Could not attach Sentry logger handler: #{inspect(reason)}")
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

  # Consumers load credentials themselves, so supervisor reports never carry
  # broker passwords. Invalid configuration and exhausted restart budgets are
  # isolated to the affected tenant subscription.
  defp maybe_add_acknowledgment_consumer(children) do
    if Application.get_env(:custyard, :env) == :test,
      do: children,
      else: children ++ [Custyard.Acknowledgments.Subscriptions]
  end

  # Public-intake background sweeps (expired slug claims, retention bounds).
  # Flagged off in config/test.exs — tests drive the sweep functions
  # directly with an injected clock or explicit options.
  defp maybe_add_intake_sweeps(children) do
    if Application.get_env(:custyard, :start_intake_sweeps, true) do
      children ++ [Custyard.Slugs.ClaimExpiry, Custyard.Threads.RetentionSweep]
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

  defp maybe_add_imap_pollers(children) do
    if Application.get_env(:custyard, :start_imap_pollers, true),
      do: children ++ [Custyard.Email.ImapPollers],
      else: children
  end

  @impl true
  def config_change(changed, _new, removed) do
    CustyardWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
