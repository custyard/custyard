import Config

# Only reviewed deployment labels may enter operational error events.
config :custyard,
       :log_environments,
       ~w(dev test prod development production staging custyard-eu-prod)

config :custyard,
  ecto_repos: [Custyard.Repo],
  repo_adapter: Custyard.Repo.Adapter,
  generators: [timestamp_type: :utc_datetime],
  # Where earlier releases wrote tenant logos (upload_dir) and inbound email
  # attachments (attachment_dir, spec-inbound-channels D9). Files are stored in
  # the database; these only locate what such a release left behind, for a
  # one-time import and for the sweep of attachment files whose rows are
  # gone. The attachment directory is deliberately not under priv/static:
  # Plug.Static serves everything below `uploads`, and attachments are only
  # ever served through the authenticated download endpoint.
  upload_dir: Path.expand("../priv/static/uploads", __DIR__),
  attachment_dir: Path.expand("../priv/attachments", __DIR__),
  attachment_client: Custyard.Attachments.FinchClient

# Acknowledgment subscriptions are tenant records; config/runtime.exs sets
# only the consumption limit.
config :custyard, :acknowledgments, enabled: false

config :custyard, CustyardWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CustyardWeb.ErrorHTML, json: CustyardWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Custyard.PubSub

config :esbuild,
  version: "0.28.2",
  custyard: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "4.3.3",
  custyard: [
    args: ~w(
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

# The application installs a JSON formatter and a privacy filter before its
# children start. This text formatter is also used by ExUnit capture helpers;
# the primary filter has already restricted every metadata field.
config :logger, :console,
  format: "$dateT$timeZ $metadata[$level] $message\n",
  metadata: :all

config :logger, :default_formatter,
  format: "$dateT$timeZ $metadata[$level] $message\n",
  metadata: :all,
  utc_log: true

config :custyard, Custyard.Repo,
  log: false,
  show_sensitive_data_on_connection_error: false

config :phoenix, :json_library, Jason
config :phoenix, :filter_parameters, {:keep, []}

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
# Deliberately app config, not staff Settings — see
# docs/design/design-decisions-public-intake.md. Keys per bucket:
# client IP unless noted (thread_reply: token hash; claim_email_send:
# downcased email; intake_arrival_email: intake source key;
# intake_receipt_email: downcased captured email).
config :custyard, :rate_limit_buckets,
  public_instance_ip: [limit: 600, window_ms: 60_000],
  account_login_ip: [limit: 5, window_ms: 60_000],
  account_login_email: [limit: 5, window_ms: 3_600_000],
  intake_get: [limit: 60, window_ms: 60_000],
  intake_post: [limit: 5, window_ms: 3_600_000],
  thread_mount: [limit: 30, window_ms: 600_000],
  thread_reply: [limit: 20, window_ms: 3_600_000],
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

# IMAP channels (spec-inbound-channels D8): one poller per channel, set up in
# the channel wizard. The interval is per channel; failures back off up to
# 15 minutes.
config :custyard,
  imap_client: Custyard.Email.ImapClient.Plover,
  imap_poll_interval_ms: 60_000

# Build identity, reported by Custyard.Boot.Build on every boot report and
# doctor card. Evaluated when the release is built: the Containerfile exports
# GIT_SHA and BUILD_TIME (CI build args) before `mix compile`; any other build
# says "unknown".
config :custyard, :build,
  git_sha: System.get_env("GIT_SHA", "unknown"),
  built_at: System.get_env("BUILD_TIME", "unknown")

import_config "#{config_env()}.exs"
