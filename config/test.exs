import Config

config :custyard, env: :test

config :custyard, Custyard.Repo,
  database: Path.expand("../priv/repo/custyard_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox,
  journal_mode: :wal,
  # High busy_timeout needed because SQLite only allows one writer at a time
  # and async tests cause write contention
  busy_timeout: 30_000,
  queue_target: 500,
  queue_interval: 1000

config :custyard, CustyardWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_that_is_at_least_64_bytes_long_for_testing_only_abc",
  live_view: [signing_salt: "test_only_signing_salt_for_automated_testing"],
  server: false

config :logger, level: :warning

# Disable scoring scheduler in tests to avoid sandbox conflicts
config :custyard, start_scheduler: false

# Allow ?as=<contact_id> param for testing contact impersonation
config :custyard, allow_contact_impersonation: true

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Use test adapter for Swoosh to capture emails in tests
config :custyard, Custyard.Mailer, adapter: Swoosh.Adapters.Test

# Webhook token for tests
config :custyard, :webhook_token, "test_webhook_token"
