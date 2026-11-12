import Config

# This file never raises. In production the environment is parsed once by
# Custyard.Boot.Env, which reports every missing or malformed variable as a
# problem; Custyard.Application reads the verdict and either starts the app or
# serves the doctor card (docs/backlog/1103-first-run-experience.md). Whatever
# is valid is configured below so that the endpoint, the mailer and the
# release commands have something to run with.

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

# Tenant integration records own subscription credentials, queues and enabled
# state. Consumption limits remain deployment settings. A prefetch out of
# range is reported by Custyard.Boot.Env; here it falls back to the default.
acknowledgments_prefetch =
  with value when is_binary(value) <- System.get_env("ACKNOWLEDGMENTS_PREFETCH"),
       {count, ""} when count > 0 and count <= 100 <- Integer.parse(value) do
    count
  else
    _ -> 1
  end

config :custyard, :acknowledgments, prefetch: acknowledgments_prefetch

# An installation-level stop for recovery and provider incidents. Never start
# restored mail workers until an operator has reconciled the archived queue.
# Production takes this, and the attachment scanner, from Custyard.Boot.Env
# below, which reports a malformed value as a problem. Outside production a
# value that is neither true nor false keeps delivery stopped: a mistyped
# "false" must not send.
if config_env() != :prod do
  config :custyard,
         :outbound_delivery_enabled,
         System.get_env("OUTBOUND_DELIVERY_ENABLED") in [nil, "", "true"]

  # clamd must be reachable only through a trusted private network. Without an
  # endpoint attachments remain quarantined; receiving email remains available.
  if clamav_host = blank_to_nil.(System.get_env("CLAMAV_HOST")) do
    clamav_port = parse_int.("CLAMAV_PORT", 3310)
    clamav_timeout = parse_int.("CLAMAV_TIMEOUT_MS", 10_000)

    if clamav_port in 1..65_535 and clamav_timeout in 100..60_000 do
      config :custyard,
        attachment_scanner: Custyard.Attachments.ClamAV,
        attachment_scanner_options: [
          host: clamav_host,
          port: clamav_port,
          timeout: clamav_timeout
        ]
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

# IMAP channels (spec-inbound-channels D8) replaced the single global IMAP
# poller. A leftover IMAP_ENABLED is a Custyard.Boot.Env problem in
# production; the flag only keeps Custyard.Application from starting pollers.
config :custyard,
  legacy_imap_enabled: blank_to_nil.(System.get_env("IMAP_ENABLED")) not in [nil, "false"]

# Encryption key for stored third-party credentials such as IMAP channel
# passwords (Custyard.Credentials), Base64 of 32 bytes. Outside production
# an explicit key is read here; a malformed one is ignored (config/test.exs
# sets a test key). Production requires it and takes it from Custyard.Boot.Env
# below; it is never derived from SECRET_KEY_BASE, so the two rotate
# independently.
if config_env() != :prod do
  parse_credential_key = fn encoded ->
    case Base.decode64(String.trim(encoded)) do
      {:ok, <<_::binary-size(32)>> = key} -> key
      _ -> nil
    end
  end

  case blank_to_nil.(System.get_env("CREDENTIAL_ENCRYPTION_KEY")) do
    nil ->
      :ok

    encoded ->
      previous =
        case blank_to_nil.(System.get_env("CREDENTIAL_ENCRYPTION_KEY_PREVIOUS")) do
          nil -> []
          old -> [parse_credential_key.(old)]
        end

      config :custyard, :credential_keys,
        current: parse_credential_key.(encoded),
        previous: Enum.reject(previous, &is_nil/1)
  end
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

if config_env() == :prod do
  env = Custyard.Boot.Env.read(System.get_env(), config_env: config_env())
  config :custyard, :boot_env, env
  settings = env.settings

  # Hosting, proxy trust and database provider are independent. Fly staging
  # may use Bunny Database behind Fly's proxy. Custyard.Storage applies the
  # storage provider's rules for where the database lives before the Repo
  # starts.
  #
  # Rate limiting keys on the client IP. Behind an edge proxy every request
  # arrives from the proxy address, so without header trust all visitors
  # would collapse into one shared bucket. Trust is never enabled without a
  # proxy provider, where the spoofable headers would come straight from
  # clients; CustyardWeb.ClientIP only honors proxy-authoritative values, and
  # CustyardWeb.Proxy authenticates Bunny's origin (BUNNY_ORIGIN_SECRET)
  # before trusting its forwarded headers. With that secret missing or short
  # the setting is nil and the proxy refuses every request but the health
  # probes.
  config :custyard,
    storage_provider: settings.storage_provider,
    proxy_provider: settings.proxy_provider,
    bunny_origin_secret: settings.bunny_origin_secret,
    trust_proxy_headers: settings.trust_proxy_headers

  # Staff login is magic-link-only, so an unset or unknown MAIL_ADAPTER is
  # a configuration problem (Custyard.Boot.Env), not a silent fallback to the
  # in-memory adapter. A recognized adapter is configured even while its
  # credential is missing: the problem is reported and the app does not
  # start, but the doctor card and the release commands still load.
  if settings.mail do
    config :custyard, Custyard.Mailer, settings.mail.config

    # Tenant credentials may select Lettermint independently of the installation
    # adapter, including SMTP or Local, and can be saved after the app boots.
    config :swoosh, api_client: Swoosh.ApiClient.Finch, finch_name: Custyard.Finch
  end

  # Email notifications for neglect alerts and system events
  # (Custyard.Notifications.Email), delivered to each tenant's staff.
  # Defaults: on unless MAIL_ADAPTER=local, from noreply@PHX_HOST.
  notifications = settings.notifications

  config :custyard,
    email_enabled: notifications.enabled,
    email_from_name: notifications.from_name,
    email_from_address: notifications.from_address || "alerts@custyard.local"

  config :custyard, :outbound_delivery_enabled, settings.outbound_delivery_enabled

  if scanner = settings.attachment_scanner do
    config :custyard,
      attachment_scanner: Custyard.Attachments.ClamAV,
      attachment_scanner_options: [
        host: scanner.host,
        port: scanner.port,
        timeout: scanner.timeout
      ]
  end

  config :custyard, :credential_keys,
    current: settings.credential_keys.current,
    previous: settings.credential_keys.previous

  # Without SECRET_KEY_BASE nothing is signed: the doctor card is served
  # with a throwaway key so the endpoint can start at all.
  secret_key_base = settings.secret_key_base || Base.encode64(:crypto.strong_rand_bytes(64))
  host = settings.host || "localhost"

  # Derive session and LiveView salts from SECRET_KEY_BASE
  # This ensures unique salts per deployment without requiring additional env vars.
  # Falls back to env vars if explicitly set (for backward compatibility or rotation).
  session_signing_salt =
    blank_to_nil.(System.get_env("SESSION_SIGNING_SALT")) ||
      Base.encode64(:crypto.hash(:sha256, "session_signing:" <> secret_key_base), padding: false)

  session_encryption_salt =
    blank_to_nil.(System.get_env("SESSION_ENCRYPTION_SALT")) ||
      Base.encode64(:crypto.hash(:sha256, "session_encryption:" <> secret_key_base),
        padding: false
      )

  live_view_signing_salt =
    blank_to_nil.(System.get_env("LIVE_VIEW_SIGNING_SALT")) ||
      Base.encode64(:crypto.hash(:sha256, "live_view:" <> secret_key_base), padding: false)

  config :custyard, CustyardWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: settings.port
    ],
    # MFA callback for dynamic origin validation (custom domains from DB)
    # Note: [[]] passes empty list as 2nd arg to match check_origin?/2 arity
    check_origin: {CustyardWeb.OriginValidator, :check_origin?, [[]]},
    secret_key_base: secret_key_base,
    live_view: [signing_salt: live_view_signing_salt],
    # Session salts derived from secret_key_base for security
    session_signing_salt: session_signing_salt,
    session_encryption_salt: session_encryption_salt

  repo_adapter = Application.get_env(:custyard, :repo_adapter, Custyard.Repo.Adapter)

  case settings.database do
    {:sqlite, path} ->
      config :custyard, Custyard.Repo,
        database: path,
        pool_size: settings.pool_size,
        journal_mode: :wal,
        busy_timeout: 5000

    {:turso, url, token} ->
      # Turso or Bunny Database: the same SQLite database, reached over HTTP
      # by Custyard.Turso.Connection (Hrana v3 for Turso, v2 for Bunny).
      # `turso db show --url` prints the Turso URL.
      config :custyard, Custyard.Repo,
        turso_url: url,
        turso_auth_token: token,
        turso_provider: settings.turso_provider,
        pool_size: settings.pool_size

    {:postgres, url} when repo_adapter == Ecto.Adapters.Postgres ->
      config :custyard, Custyard.Repo,
        url: url,
        pool_size: settings.pool_size

    _unsupported_or_nil ->
      # A malformed URL or path is a Custyard.Boot.Env problem; a postgres://
      # URL on the SQLite/libSQL build is reported by Custyard.Boot.Probe.
      # Either way the Repo stays unconfigured and is never started.
      :ok
  end

  # Where earlier releases wrote tenant logos (UPLOAD_DIR) and inbound email
  # attachments (ATTACHMENT_DIR). Files are stored in the database; these
  # only locate what such a release left behind, for a one-time import.
  # Neither is validated or has to exist.
  config :custyard,
    upload_dir: settings.upload_dir,
    attachment_dir: settings.attachment_dir
end
