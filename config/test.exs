import Config

config :custyard, env: :test

config :custyard, Custyard.Repo,
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox,
  queue_target: 500,
  queue_interval: 1000

# TURSO_TEST_URL (a libsql:// URL) runs the suite over the Turso driver
# against that server; CI's turso job points it at a libSQL server.
case System.get_env("TURSO_TEST_URL") do
  url when url in [nil, ""] ->
    config :custyard, Custyard.Repo,
      database:
        Path.expand(
          "../priv/repo/custyard_test#{System.get_env("MIX_TEST_PARTITION")}.db",
          __DIR__
        ),
      journal_mode: :wal,
      # High busy_timeout needed because SQLite only allows one writer at a time
      # and async tests cause write contention
      busy_timeout: 30_000

  url ->
    config :custyard, Custyard.Repo,
      turso_url: url,
      turso_auth_token: System.get_env("TURSO_TEST_AUTH_TOKEN")
end

config :custyard, CustyardWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "test_secret_key_base_that_is_at_least_64_bytes_long_for_testing_only_abc",
  live_view: [signing_salt: "test_only_signing_salt_for_automated_testing"],
  server: false

config :logger, level: :warning

# Disable scoring scheduler in tests to avoid sandbox conflicts
config :custyard, start_scheduler: false

# Disable public-intake background sweeps (slug claim expiry) in tests;
# the sweep functions take an injectable clock and are tested directly.
config :custyard, start_intake_sweeps: false

# Drive the durable outbound scan explicitly in tests; a background scan would
# outlive the SQL sandbox owner.
config :custyard, start_outbound_queue: false

# Public-intake notification mail still uses supervised tasks. Keep those
# synchronous in tests so their database reads stay with the sandbox owner.
config :custyard, deliver_replies_async?: false

# Allow ?as=<contact_id> param for testing contact impersonation
config :custyard, allow_contact_impersonation: true

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Attachments land in a throwaway directory and are fetched from an in-memory
# stub instead of the network (Custyard.Attachments.StubClient, test/support).
config :custyard,
  attachment_dir:
    Path.expand("../tmp/test_attachments#{System.get_env("MIX_TEST_PARTITION")}", __DIR__),
  attachment_client: Custyard.Attachments.StubClient

# Use test adapter for Swoosh to capture emails in tests
config :custyard, Custyard.Mailer, adapter: Swoosh.Adapters.Test

# Never send real events to the live Sentry instance from the test suite,
# even if SENTRY_DSN leaks into the environment (CI, a developer's shell).
# Sentry.Test.setup_sentry/1 overrides this per-test with a local Bypass DSN.
config :sentry, dsn: nil

# Test key for stored IMAP channel passwords (Custyard.Credentials).
config :custyard, :credential_keys,
  current: :crypto.hash(:sha256, "custyard test credential key"),
  previous: []

# IMAP channels poll through a stub client keyed by host name, passed
# through unresolved; no pollers start with the app.
config :custyard,
  start_imap_pollers: false,
  imap_client: Custyard.Email.ImapClient.Stub,
  imap_allow_private_hosts: true

# Exercise tenant credentials through the real provider adapter while keeping
# delivery inside Swoosh's test transport.
config :swoosh, :api_client, Custyard.TestTenantMailClient
