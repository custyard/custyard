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

# Treat a blank env var as unset.
#
# `""` is truthy in Elixir, so `if System.get_env("X")` passes for a secret
# that exists with an empty value. `.env.secrets.sample` ships credential keys
# empty by design and `mix fly.secrets --apply` syncs whatever is in the file,
# so blank-but-present is a realistic state, not a hypothetical one.
blank_to_nil = fn
  nil -> nil
  "" -> nil
  value -> value
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
  # MAIL_ADAPTER is required in prod, and "local" must be chosen explicitly.
  #
  # The old behaviour — unset or misspelled silently keeps Swoosh's
  # in-memory Local adapter — is the worst kind of failure this app has.
  # Operator login is magic-link-only, so a discarded mail queue is not
  # degraded service, it is total lockout: nobody can sign in, and every
  # claim confirmation, arrival notification, and prospect receipt is
  # accepted and thrown away with no error anywhere. Refusing to boot
  # surfaces it at deploy time, while Fly still has the previous machine.
  #
  # This is deliberately stricter than the Lettermint route-provisioning
  # warning below, which degrades to a MockClient that provisions nothing
  # but breaks nothing.
  known_mail_adapters = ~w(mailgun sendgrid smtp postmark lettermint local)

  mail_adapter =
    case System.get_env("MAIL_ADAPTER") do
      nil -> nil
      "" -> nil
      value -> value
    end

  cond do
    is_nil(mail_adapter) ->
      raise """
      MAIL_ADAPTER is not set.

      Set it to one of: #{Enum.join(known_mail_adapters, ", ")}

      Operator login is magic-link-only, so an instance without working
      mail cannot be signed into at all. Use MAIL_ADAPTER=local to run
      without outbound mail on purpose — it discards every message.
      """

    mail_adapter not in known_mail_adapters ->
      raise """
      MAIL_ADAPTER is set to #{inspect(mail_adapter)}, which is not recognized.

      Set it to one of: #{Enum.join(known_mail_adapters, ", ")}

      An unrecognized value used to fall through to the in-memory Local
      adapter, which accepts and discards every message — including the
      magic links operators sign in with.
      """

    true ->
      :ok
  end

  if mail_adapter == "local" do
    IO.warn("""
    MAIL_ADAPTER=local: outbound mail is discarded.

    Magic-link logins, prospect receipts, and operator notifications will
    not be delivered. This is only appropriate for a smoke-test instance.
    """)
  end

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
          api_token: blank_to_nil.(System.get_env("LETTERMINT_API_KEY")),
          base_url: blank_to_nil.(System.get_env("LETTERMINT_API_URL"))

      "local" ->
        # Explicitly opted into the in-memory adapter; warned about above.
        # Unrecognized values never reach here — they raise.
        :ok
    end

    # API-based adapters need a real Swoosh API client. config.exs disables it
    # globally (:api_client, false) since dev/test use the Local adapter, so we
    # re-enable it here and point it at the Finch instance from the supervision tree.
    if mail_adapter in ~w(mailgun sendgrid postmark lettermint) do
      config :swoosh, :api_client, Swoosh.ApiClient.Finch
      config :swoosh, :finch_name, Custyard.Finch
    end
  end
end

# Error tracking (self-hosted Sentry). Prod-only on purpose: reading SENTRY_DSN
# in every environment would let a stray env var in CI or a dev shell ship real
# events to the production instance, and would override the dsn: nil guard that
# config/test.exs sets at compile time. With no SENTRY_DSN the SDK stays
# disabled (nil DSN => no events). Base options live in config/config.exs.
if config_env() == :prod do
  sentry_dsn =
    case System.get_env("SENTRY_DSN") do
      nil -> nil
      "" -> nil
      dsn -> dsn
    end

  if sentry_dsn do
    config :sentry,
      dsn: sentry_dsn,
      # Distinguish deployments (e.g. "custyard-eu-prod"); defaults to "production".
      environment_name: System.get_env("SENTRY_ENVIRONMENT") || "production"

    # Optional release identifier for grouping errors by deploy. Only set when
    # provided so the SDK's own fallback is used otherwise.
    case System.get_env("SENTRY_RELEASE") do
      nil -> :ok
      "" -> :ok
      release -> config :sentry, release: release
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

# Lettermint API configuration (route management).
#
# Blank is treated as unset: a key that synced with an empty value would
# otherwise wire up the real HttpClient with no credential, so every
# provisioning call fails at the API instead of falling back to the MockClient,
# which at least announces itself at boot.
lettermint_api_url = blank_to_nil.(System.get_env("LETTERMINT_API_URL"))
lettermint_api_key = blank_to_nil.(System.get_env("LETTERMINT_API_KEY"))

if lettermint_api_url && lettermint_api_key do
  config :custyard, :lettermint,
    client: Custyard.Lettermint.HttpClient,
    api_url: lettermint_api_url,
    api_key: lettermint_api_key

  config :custyard, :lettermint_configured, true
else
  if config_env() == :prod do
    IO.warn("""
    Lettermint is not configured. Route provisioning will be disabled.

    To enable, set these environment variables:
      - LETTERMINT_API_URL
      - LETTERMINT_API_KEY

    Falling back to MockClient.
    """)

    config :custyard, :lettermint, client: Custyard.Lettermint.MockClient
    config :custyard, :lettermint_configured, false
  end
end

# Rate limiting keys on the client IP. Behind Fly's edge proxy every
# request arrives from the proxy address, so without header trust all
# visitors would collapse into one shared bucket. FLY_APP_NAME is set by
# the Fly platform itself; trust is never enabled off-Fly, where the
# spoofable headers would come straight from clients. CustyardWeb.ClientIP
# only honors proxy-authoritative values (Fly-Client-IP, rightmost
# X-Forwarded-For), so enabling trust here does not open a spoof bypass.
if config_env() == :prod and System.get_env("FLY_APP_NAME") do
  config :custyard, :trust_proxy_headers, true
end

if config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  # Email-only auth: operators log in via magic link, no password needed.
  # OPERATOR_PASSWORD is no longer required.

  host = System.get_env("PHX_HOST") || "localhost"
  port = parse_int.("PORT", 4000)

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

      # DANGER: production on a local SQLite file means the DB lives on the
      # ephemeral rootfs and is destroyed on every deploy/restart/migration.
      # Flag it so the app renders a persistent warning banner (see #71).
      config :custyard, :ephemeral_db_warning?, true
  end

  # Persistent upload directory (survives deployments, unlike priv/static)
  config :custyard,
    upload_dir: System.get_env("UPLOAD_DIR") || "/data/uploads"
end
