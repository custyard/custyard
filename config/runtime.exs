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

# Tenant integration records own subscription credentials, queues and enabled state.
# Consumption limits remain deployment settings.
acknowledgments_prefetch =
  case System.get_env("ACKNOWLEDGMENTS_PREFETCH") do
    value when value in [nil, ""] ->
      1

    value ->
      case Integer.parse(value) do
        {count, ""} when count > 0 and count <= 100 -> count
        _ -> raise "ACKNOWLEDGMENTS_PREFETCH must be an integer between 1 and 100"
      end
  end

config :custyard, :acknowledgments, prefetch: acknowledgments_prefetch

# Configure Swoosh mailer for production
if config_env() == :prod do
  # MAIL_ADAPTER is required in prod, and "local" must be chosen explicitly.
  #
  # The old behaviour — unset or misspelled silently keeps Swoosh's
  # in-memory Local adapter — is the worst kind of failure this app has.
  # Staff login is magic-link-only, so a discarded mail queue is not
  # degraded service, it is total lockout: nobody can sign in, and every
  # claim confirmation, arrival notification, and prospect receipt is
  # accepted and thrown away with no error anywhere. Refusing to boot
  # surfaces it at deploy time, while Fly still has the previous machine.
  #
  # This is deliberately stricter than the Lettermint route-provisioning
  # management configuration below, which can remain unavailable without
  # preventing staffs from opening existing threads.
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

      Staff login is magic-link-only, so an instance without working
      mail cannot be signed into at all. Use MAIL_ADAPTER=local to run
      without outbound mail on purpose — it discards every message.
      """

    mail_adapter not in known_mail_adapters ->
      raise """
      MAIL_ADAPTER is set to #{inspect(mail_adapter)}, which is not recognized.

      Set it to one of: #{Enum.join(known_mail_adapters, ", ")}

      An unrecognized value used to fall through to the in-memory Local
      adapter, which accepts and discards every message — including the
      magic links staffs sign in with.
      """

    true ->
      :ok
  end

  if mail_adapter == "local" do
    IO.warn("""
    MAIL_ADAPTER=local: outbound mail is discarded.

    Magic-link logins, prospect receipts, and staff notifications will
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
          api_token: blank_to_nil.(System.get_env("LETTERMINT_PROJECT_TOKEN")),
          base_url:
            blank_to_nil.(System.get_env("LETTERMINT_API_URL")) || "https://api.lettermint.co/v1"

      "local" ->
        # Explicitly opted into the in-memory adapter; warned about above.
        # Unrecognized values never reach here — they raise.
        :ok
    end

    # Tenant credentials may select Lettermint independently of the installation
    # adapter, including SMTP or Local, and can be saved after the app boots.
    config :swoosh, api_client: Swoosh.ApiClient.Finch, finch_name: Custyard.Finch
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

# Encryption key for stored third-party credentials such as IMAP channel
# passwords (Custyard.Credentials). Base64 of 32 bytes. A malformed key fails
# here; a missing one only blocks storing a credential.
parse_credential_key = fn encoded, name ->
  case Base.decode64(String.trim(encoded)) do
    {:ok, <<_::binary-size(32)>> = key} -> key
    _ -> raise "#{name} must be Base64 of exactly 32 bytes (openssl rand -base64 32)"
  end
end

case blank_to_nil.(System.get_env("CREDENTIAL_ENCRYPTION_KEY")) do
  nil ->
    if config_env() == :prod, do: config(:custyard, :credential_keys, current: nil, previous: [])

  encoded ->
    previous =
      case blank_to_nil.(System.get_env("CREDENTIAL_ENCRYPTION_KEY_PREVIOUS")) do
        nil -> []
        old -> [parse_credential_key.(old, "CREDENTIAL_ENCRYPTION_KEY_PREVIOUS")]
      end

    config :custyard, :credential_keys,
      current: parse_credential_key.(encoded, "CREDENTIAL_ENCRYPTION_KEY"),
      previous: previous
end

# Support provider credentials are encrypted tenant records. Only the API
# endpoint and implementation are installation configuration.
config :custyard, :lettermint,
  client:
    if(config_env() == :test,
      do: Custyard.Lettermint.MockClient,
      else: Custyard.Lettermint.HttpClient
    ),
  api_url: blank_to_nil.(System.get_env("LETTERMINT_API_URL")) || "https://api.lettermint.co/v1"

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

  # Email-only auth: staffs log in via magic link, no password needed.
  # Instance administrators use email-only authentication.

  host = System.get_env("PHX_HOST") || "localhost"
  port = parse_int.("PORT", 4000)

  # Email notifications for neglect alerts and system events
  # These configure the Notifications.Email module for sending alert emails
  config :custyard,
    email_enabled: System.get_env("EMAIL_NOTIFICATIONS_ENABLED") == "true",
    email_from_name: System.get_env("EMAIL_FROM_NAME") || "Custyard Alerts",
    email_from_address: System.get_env("EMAIL_FROM_ADDRESS") || "alerts@custyard.local"

  # Derive session and LiveView salts from SECRET_KEY_BASE
  # This ensures unique salts per deployment without requiring additional env vars.
  # Explicit salt variables support installation-specific configuration and rotation.
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
  repo_adapter = Application.get_env(:custyard, :repo_adapter, Custyard.Repo.Adapter)

  cond do
    is_binary(database_url) and String.starts_with?(database_url, "libsql://") and
        repo_adapter == Custyard.Repo.Adapter ->
      # Turso: the same SQLite database, reached over HTTP by
      # Custyard.Turso.Connection. `turso db show --url` prints this URL.
      turso_auth_token = blank_to_nil.(System.get_env("TURSO_AUTH_TOKEN"))

      plain_http? =
        database_url
        |> URI.parse()
        |> Map.get(:query)
        |> to_string()
        |> URI.decode_query()
        |> Map.get("tls") == "0"

      # A Turso database always needs a token. Only a libSQL server on plain
      # HTTP (?tls=0), such as one on a private network, may run without auth.
      if is_nil(turso_auth_token) and not plain_http? do
        raise """
        DATABASE_URL is a libsql:// URL but TURSO_AUTH_TOKEN is not set.
        Create a token with `turso db tokens create <database>` and set it:

            fly secrets set TURSO_AUTH_TOKEN=...
        """
      end

      config :custyard, Custyard.Repo,
        turso_url: database_url,
        turso_auth_token: turso_auth_token,
        pool_size: pool_size

    is_binary(database_url) and repo_adapter == Ecto.Adapters.Postgres and
        (String.starts_with?(database_url, "postgres://") or
           String.starts_with?(database_url, "postgresql://")) ->
      config :custyard, Custyard.Repo,
        url: database_url,
        pool_size: pool_size

    is_binary(database_url) ->
      raise "DATABASE_URL is not supported by the compiled #{inspect(repo_adapter)} adapter"

    repo_adapter == Ecto.Adapters.Postgres ->
      raise "DATABASE_URL is required when the app is compiled with Ecto.Adapters.Postgres"

    repo_adapter == Custyard.Repo.Adapter ->
      database_path = System.get_env("DATABASE_PATH") || "/data/custyard.db"

      if Path.type(database_path) != :absolute do
        raise "DATABASE_PATH must be an absolute filesystem path"
      end

      config :custyard, Custyard.Repo,
        database: database_path,
        pool_size: pool_size,
        journal_mode: :wal,
        busy_timeout: 5000

    true ->
      raise "No production database configuration for #{inspect(repo_adapter)}"
  end

  # Persistent upload directory (survives deployments, unlike priv/static)
  config :custyard,
    upload_dir: System.get_env("UPLOAD_DIR") || "/data/uploads",
    # Inbound email attachments, served only through the authenticated
    # staff endpoint (never a static path).
    attachment_dir: System.get_env("ATTACHMENT_DIR") || "/data/attachments"
end
