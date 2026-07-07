defmodule Custyard.Application do
  @moduledoc false

  use Application

  require Logger

  @default_operator_email "admin@custyard.local"

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

    # Check for dangerous SQLite + ephemeral storage configuration
    warn_if_ephemeral_sqlite()

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
      |> maybe_add_lmtp_server()
      |> maybe_add_imap_poller()

    opts = [strategy: :one_for_one, name: Custyard.Supervisor]
    result = Supervisor.start_link(children, opts)

    # Setup operator account after supervisor fully starts
    # Use Task to avoid blocking application startup
    if Application.get_env(:custyard, :env) == :dev do
      Task.start(fn -> setup_dev_operator() end)
    end

    result
  end

  # Detect dangerous configuration: local SQLite with ephemeral /data path on Fly.io
  # This would cause data loss on every deploy/restart without a persistent volume mount.
  defp warn_if_ephemeral_sqlite do
    repo_config = Application.get_env(:custyard, Custyard.Repo, [])
    database_path = Keyword.get(repo_config, :database)
    upload_dir = Application.get_env(:custyard, :upload_dir)

    # Check if using SQLite (database_path is set, not using Turso/Postgres via url)
    using_sqlite? = is_binary(database_path) and not Keyword.has_key?(repo_config, :url)

    if using_sqlite? do
      check_ephemeral_path(database_path, "DATABASE_PATH", "database")
    end

    if is_binary(upload_dir) do
      check_ephemeral_path(upload_dir, "UPLOAD_DIR", "uploads")
    end
  end

  defp check_ephemeral_path(path, env_var, description) do
    # /data is Fly.io's convention for mounted volumes, but without a mount it's ephemeral
    if String.starts_with?(path, "/data") do
      parent_dir = Path.dirname(path)

      cond do
        # If /data doesn't exist at all, the mount is definitely missing
        not File.exists?("/data") ->
          Logger.error("""

          ╔═══════════════════════════════════════════════════════════════════════════════╗
          ║ CRITICAL: DATA LOSS RISK - EPHEMERAL STORAGE DETECTED                         ║
          ╠═══════════════════════════════════════════════════════════════════════════════╣
          ║ #{description} path: #{path}
          ║
          ║ The /data directory does not exist. On Fly.io, this means no persistent
          ║ volume is mounted. All data will be LOST on deploy, restart, or auto-stop.
          ║
          ║ To fix: uncomment [mounts] in fly.toml and create a volume:
          ║   fly volumes create custyard_data --region <your-region> --size 1
          ║
          ║ Or set #{env_var} to use a different storage location.
          ╚═══════════════════════════════════════════════════════════════════════════════╝
          """)

        # If parent dir doesn't exist and can't be created, warn
        not File.exists?(parent_dir) ->
          case File.mkdir_p(parent_dir) do
            :ok ->
              :ok

            {:error, reason} ->
              Logger.warning("""
              Cannot create #{description} directory #{parent_dir}: #{inspect(reason)}
              Ensure the path is writable or set #{env_var} to a different location.
              """)
          end

        # Path exists but may still be ephemeral - provide info-level notice
        true ->
          # On Fly.io, check if this looks like a mounted volume by checking for .fly-volume marker
          # or just log an info message since we can't be certain
          if System.get_env("FLY_APP_NAME") != nil and not File.exists?("/data/.fly-volume") do
            Logger.info("""
            Using /data for #{description}. Ensure a persistent volume is mounted in fly.toml
            to prevent data loss. If using Turso for the database, this warning can be ignored.
            """)
          end
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

  defp maybe_add_imap_poller(children) do
    imap_config = Application.get_env(:custyard, :imap, [])

    if Keyword.get(imap_config, :enabled, false) do
      # Build credential_fetcher from env var name to avoid storing credentials
      # in Application config (visible in crash dumps and :sys.get_state).
      cred_env_var = Keyword.get(imap_config, :credential_env_var, "IMAP_PASSWORD")
      credential_fetcher = fn -> System.get_env(cred_env_var) || "" end

      opts = [
        host: Keyword.get(imap_config, :host, "localhost"),
        port: Keyword.get(imap_config, :port, 993),
        username: Keyword.get(imap_config, :username, ""),
        credential_fetcher: credential_fetcher,
        folder: Keyword.get(imap_config, :folder, "INBOX"),
        poll_interval: Keyword.get(imap_config, :poll_interval, 60_000),
        ssl: Keyword.get(imap_config, :ssl, true)
      ]

      children ++ [{Custyard.Email.ImapPoller, opts}]
    else
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
      Logger.warning("Failed to setup dev operator: #{inspect(e)}")
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
    alias Custyard.{OperatorAccount, Repo}

    case Repo.get_by(OperatorAccount, email: @default_operator_email) do
      nil ->
        %OperatorAccount{}
        |> OperatorAccount.changeset(%{email: @default_operator_email})
        |> Repo.insert!()

        Logger.info("""

        ========================================
        DEV OPERATOR ACCOUNT CREATED
        ========================================
        Email: #{@default_operator_email}

        Login at: /operator/login
        A magic link will be sent to your email.
        (In dev, check the Swoosh local mailbox at /dev/mailbox)
        ========================================
        """)

      _operator ->
        Logger.debug("Dev operator account exists, skipping creation")
    end
  end

  # Helper for startup logging (uncomment with debug block above)
  # defp origin_type({m, f, a}) when is_atom(m) and is_atom(f) and is_list(a), do: "MFA"
  # defp origin_type(:conn), do: ":conn atom"
  # defp origin_type(list) when is_list(list), do: "static list"
  # defp origin_type(bool) when is_boolean(bool), do: "boolean"
  # defp origin_type(_), do: "unknown"
end
