import Config

config :custyard,
  ecto_repos: [Custyard.Repo],
  repo_adapter: Ecto.Adapters.SQLite3,
  generators: [timestamp_type: :utc_datetime],
  upload_dir: Path.expand("../priv/static/uploads", __DIR__)

config :custyard, CustyardWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CustyardWeb.ErrorHTML, json: CustyardWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Custyard.PubSub

config :esbuild,
  version: "0.24.0",
  custyard: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "4.0.9",
  custyard: [
    args: ~w(
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [
    :request_id,
    :actual_size,
    :client_hostname,
    :command,
    :current_count,
    :declared_size,
    :error_type,
    :extension,
    :hostname,
    :limit_type,
    :max_recipients,
    :max_size,
    :message_count,
    :messages_processed,
    :peer,
    :reason,
    :received_count,
    :recipient,
    :recipient_count,
    :sender,
    :size_bytes
  ]

config :phoenix, :json_library, Jason

# Error tracking (self-hosted Sentry at catch.onetimesecret.com).
#
# The DSN is deliberately NOT set here — it is read from SENTRY_DSN at runtime
# (config/runtime.exs). With no DSN, the SDK records nothing, so dev and test
# never emit events. config/test.exs pins dsn: nil defensively.
#
# before_send is the fail-closed scrubbing choke point for every event; see
# Custyard.Sentry. Performance tracing is intentionally left off (no
# traces_sample_rate) for the first cut: it is errors-only, and trace spans
# capture DB query params (more PII surface) and pull in OpenTelemetry deps.
# Enable deliberately later if wanted.
config :sentry,
  environment_name: config_env(),
  enable_source_code_context: true,
  root_source_code_paths: [File.cwd!()],
  before_send: {Custyard.Sentry, :before_send}

# Rate-limit buckets for the public intake surfaces (Custyard.RateLimit).
# Deliberately app config, not operator Settings — see
# docs/design/design-decisions-public-intake.md. Keys per bucket:
# client IP unless noted (conversation_reply: token hash; claim_email_send:
# downcased email; intake_arrival_email: intake source key;
# intake_receipt_email: downcased captured email).
config :custyard, :rate_limit_buckets,
  intake_get: [limit: 60, window_ms: 60_000],
  intake_post: [limit: 5, window_ms: 3_600_000],
  conversation_mount: [limit: 30, window_ms: 600_000],
  conversation_reply: [limit: 20, window_ms: 3_600_000],
  email_capture: [limit: 5, window_ms: 3_600_000],
  claim_submit: [limit: 3, window_ms: 3_600_000],
  claim_confirm: [limit: 10, window_ms: 60_000],
  claim_email_send: [limit: 5, window_ms: 86_400_000],
  intake_arrival_email: [limit: 60, window_ms: 3_600_000],
  intake_receipt_email: [limit: 5, window_ms: 86_400_000]

# Swoosh mailer configuration
config :custyard, Custyard.Mailer, adapter: Swoosh.Adapters.Local

# Disable Swoosh API client (we don't need the API routes)
config :swoosh, :api_client, false

# Lettermint API client (route management)
# MockClient for dev/test by default; runtime.exs overrides when env vars are set
if config_env() in [:dev, :test] do
  config :custyard, :lettermint, client: Custyard.Lettermint.MockClient
  config :custyard, :lettermint_configured, false
end

# LMTP server configuration (for receiving emails from MTA)
# TLS options (certfile, keyfile, etc.) can be configured for STARTTLS support
config :custyard, :lmtp,
  enabled: false,
  port: 2024,
  hostname: "localhost",
  tls: []

# IMAP poller configuration (for fetching emails from IMAP mailbox)
config :custyard, :imap,
  enabled: false,
  host: "localhost",
  port: 993,
  username: "",
  password: "",
  folder: "INBOX",
  poll_interval: 60_000,
  ssl: true

import_config "#{config_env()}.exs"
