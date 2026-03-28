import Config

# Safe integer parsing helper (returns default on invalid input)
parse_int = fn env_var, default ->
  case System.get_env(env_var) do
    nil ->
      default

    "" ->
      default

    value ->
      case Integer.parse(value) do
        {int, ""} -> int
        _ -> default
      end
  end
end

# Helper to add webhook secret from env var if set
maybe_put_env_secret = fn map, key, env_var ->
  case System.get_env(env_var) do
    nil -> map
    "" -> map
    value -> Map.put(map, key, value)
  end
end

# Configure Swoosh mailer for production
if config_env() == :prod do
  # Mail configuration (optional - falls back to Local adapter if not set)
  mail_adapter = System.get_env("MAIL_ADAPTER")

  if mail_adapter do
    case mail_adapter do
      "mailgun" ->
        config :custyard, Custyard.Mailer,
          adapter: Swoosh.Adapters.Mailgun,
          api_key: System.get_env("MAILGUN_API_KEY"),
          domain: System.get_env("MAILGUN_DOMAIN")

      "sendgrid" ->
        config :custyard, Custyard.Mailer,
          adapter: Swoosh.Adapters.Sendgrid,
          api_key: System.get_env("SENDGRID_API_KEY")

      "smtp" ->
        config :custyard, Custyard.Mailer,
          adapter: Swoosh.Adapters.SMTP,
          relay: System.get_env("SMTP_HOST"),
          port: parse_int.("SMTP_PORT", 587),
          username: System.get_env("SMTP_USERNAME"),
          password: System.get_env("SMTP_PASSWORD"),
          ssl: System.get_env("SMTP_SSL") == "true",
          tls: :always,
          auth: :always

      "postmark" ->
        config :custyard, Custyard.Mailer,
          adapter: Swoosh.Adapters.Postmark,
          api_key: System.get_env("POSTMARK_API_KEY")

      "lettermint" ->
        # Swoosh.Adapters.Lettermint available since swoosh 1.17+
        config :custyard, Custyard.Mailer,
          adapter: Swoosh.Adapters.Lettermint,
          api_token: System.get_env("LETTERMINT_API_TOKEN"),
          base_url: System.get_env("LETTERMINT_BASE_URL")

      _ ->
        # Unknown adapter, keep Local
        :ok
    end
  end
end

# LMTP server configuration (all environments)
lmtp_enabled = System.get_env("LMTP_ENABLED") == "true"

if lmtp_enabled do
  # Build TLS options if certificate paths are provided
  lmtp_tls_opts =
    []
    |> then(fn opts ->
      case System.get_env("LMTP_TLS_CERTFILE") do
        nil -> opts
        path -> Keyword.put(opts, :certfile, path)
      end
    end)
    |> then(fn opts ->
      case System.get_env("LMTP_TLS_KEYFILE") do
        nil -> opts
        path -> Keyword.put(opts, :keyfile, path)
      end
    end)
    |> then(fn opts ->
      case System.get_env("LMTP_TLS_CACERTFILE") do
        nil -> opts
        path -> Keyword.put(opts, :cacertfile, path)
      end
    end)

  config :custyard, :lmtp,
    enabled: true,
    port: parse_int.("LMTP_PORT", 2024),
    hostname: System.get_env("LMTP_HOSTNAME") || "localhost",
    tls: lmtp_tls_opts,
    # Connection limits for memory-constrained environments
    # Each connection can buffer up to 25MB (max email size)
    max_connections: parse_int.("LMTP_MAX_CONNECTIONS", 100),
    num_acceptors: parse_int.("LMTP_NUM_ACCEPTORS", 5)
end

# IMAP poller configuration (all environments)
imap_enabled = System.get_env("IMAP_ENABLED") == "true"

if imap_enabled do
  config :custyard, :imap,
    enabled: true,
    host: System.get_env("IMAP_HOST") || "localhost",
    port: parse_int.("IMAP_PORT", 993),
    username: System.get_env("IMAP_USERNAME") || "",
    # Store env var name instead of actual credential to prevent exposure
    # in Application config, crash dumps, and :sys.get_state calls.
    # The ImapPoller reads this at connection time via credential_fetcher.
    credential_env_var: "IMAP_PASSWORD",
    folder: System.get_env("IMAP_FOLDER") || "INBOX",
    poll_interval: parse_int.("IMAP_POLL_INTERVAL", 60000),
    ssl: System.get_env("IMAP_SSL") != "false"
end

# Lettermint API configuration (route management)
lettermint_api_url = System.get_env("LETTERMINT_API_URL")
lettermint_api_key = System.get_env("LETTERMINT_API_KEY")

cond do
  lettermint_api_url && lettermint_api_key ->
    config :custyard, :lettermint,
      client: Custyard.Lettermint.HttpClient,
      api_url: lettermint_api_url,
      api_key: lettermint_api_key

  config_env() == :prod ->
    raise """
    Lettermint is not configured in production.

    Route provisioning requires:
      - LETTERMINT_API_URL
      - LETTERMINT_API_KEY

    Please set these environment variables.
    """

  true ->
    :ok
end

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # OPERATOR_PASSWORD is required in production for admin access.
  # The entrypoint.sh auto-generates it if not set, but if someone bypasses
  # the entrypoint (e.g., direct bin/custyard start), we must fail loudly.
  operator_password =
    System.get_env("OPERATOR_PASSWORD") ||
      raise """
      environment variable OPERATOR_PASSWORD is missing.

      This is required for operator authentication in production.
      Either:
        1. Set OPERATOR_PASSWORD environment variable, OR
        2. Use the entrypoint.sh script which auto-generates one

      To generate a password manually:
        export OPERATOR_PASSWORD=$(openssl rand -base64 12)
      """

  config :custyard, :operator_password, operator_password

  host = System.get_env("PHX_HOST") || "localhost"
  port = parse_int.("PORT", 4000)

  # Legacy webhook authentication token (for POST /api/webhook/inbound)
  # Note: Consider using routed webhooks instead which have per-source HMAC secrets
  webhook_token = System.get_env("WEBHOOK_TOKEN")

  if webhook_token do
    config :custyard, :webhook_token, webhook_token
  end

  # Per-source webhook HMAC secrets for routed webhooks (POST /api/webhook/route/:token)
  # These enable signature verification on incoming webhook requests.
  # If not configured, routed webhooks will reject requests in production.
  webhook_secrets =
    %{}
    |> maybe_put_env_secret.(:lettermint, "WEBHOOK_SECRET_LETTERMINT")
    |> maybe_put_env_secret.(:zendesk, "WEBHOOK_SECRET_ZENDESK")
    |> maybe_put_env_secret.(:intercom, "WEBHOOK_SECRET_INTERCOM")
    |> maybe_put_env_secret.(:slack, "WEBHOOK_SECRET_SLACK")

  if map_size(webhook_secrets) > 0 do
    config :custyard, :webhook_secrets, webhook_secrets
  end

  # Email notifications for neglect alerts and system events
  # These configure the Notifications.Email module for sending alert emails
  config :custyard,
    email_enabled: System.get_env("EMAIL_NOTIFICATIONS_ENABLED") == "true",
    operator_email: System.get_env("OPERATOR_NOTIFICATION_EMAIL") || "operator@example.com",
    email_from_name: System.get_env("EMAIL_FROM_NAME") || "Custyard Alerts",
    email_from_address: System.get_env("EMAIL_FROM_ADDRESS") || "alerts@custyard.local"

  # Derive session and LiveView salts from SECRET_KEY_BASE
  # This ensures unique salts per deployment without requiring additional env vars.
  # Falls back to env vars if explicitly set (for backward compatibility or rotation).
  session_signing_salt =
    System.get_env("SESSION_SIGNING_SALT") ||
      Base.encode64(:crypto.hash(:sha256, "session_signing:" <> secret_key_base), padding: false)

  session_encryption_salt =
    System.get_env("SESSION_ENCRYPTION_SALT") ||
      Base.encode64(:crypto.hash(:sha256, "session_encryption:" <> secret_key_base),
        padding: false
      )

  live_view_signing_salt =
    System.get_env("LIVE_VIEW_SIGNING_SALT") ||
      Base.encode64(:crypto.hash(:sha256, "live_view:" <> secret_key_base), padding: false)

  config :custyard, CustyardWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    # MFA callback for dynamic origin validation (custom domains from DB)
    # Note: [[]] passes empty list as 2nd arg to match check_origin?/2 arity
    check_origin: {CustyardWeb.OriginValidator, :check_origin?, [[]]},
    secret_key_base: secret_key_base,
    live_view: [signing_salt: live_view_signing_salt],
    # Session salts derived from secret_key_base for security
    session_signing_salt: session_signing_salt,
    session_encryption_salt: session_encryption_salt

  database_url =
    case System.get_env("DATABASE_URL") do
      nil -> nil
      "" -> nil
      url -> url
    end

  pool_size = parse_int.("POOL_SIZE", 10)

  cond do
    is_binary(database_url) and String.starts_with?(database_url, "libsql://") ->
      # Turso/libSQL: pass URL as :database with auth token
      config :custyard, Custyard.Repo,
        database: database_url,
        token: System.get_env("TURSO_AUTH_TOKEN"),
        pool_size: pool_size

    is_binary(database_url) ->
      # Postgres-style URL
      config :custyard, Custyard.Repo,
        url: database_url,
        pool_size: pool_size

    true ->
      # Default: local SQLite file
      # WAL mode is essential for concurrent read/write performance
      # busy_timeout handles write contention (Scoring.Recalculator runs bulk updates)
      config :custyard, Custyard.Repo,
        database: System.get_env("DATABASE_PATH") || "/data/custyard.db",
        pool_size: pool_size,
        journal_mode: :wal,
        busy_timeout: 5000
  end

  # Persistent upload directory (survives deployments, unlike priv/static)
  config :custyard,
    upload_dir: System.get_env("UPLOAD_DIR") || "/data/uploads"
end
