import Config

config :custyard, Custyard.Repo,
  database: Path.expand("../priv/repo/custyard_test.db", __DIR__),
  pool_size: 1,
  pool: Ecto.Adapters.SQL.Sandbox,
  journal_mode: :wal,
  busy_timeout: 5000

config :custyard, CustyardWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_that_is_at_least_64_bytes_long_for_testing_only_abc",
  server: false

config :logger, level: :warning

# Disable scoring scheduler in tests to avoid sandbox conflicts
config :custyard, start_scheduler: false

# Allow ?as=<contact_id> param for testing contact impersonation
config :custyard, allow_contact_impersonation: true

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  enable_expensive_runtime_checks: true
