import Config

config :custyard, env: :dev

config :custyard, Custyard.Repo,
  database: Path.expand("../priv/repo/custyard_dev.db", __DIR__),
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true,
  journal_mode: :wal,
  busy_timeout: 5000

config :custyard, CustyardWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: ["//localhost:4000", "//127.0.0.1:4000"],
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "dev_secret_key_base_that_is_at_least_64_bytes_long_for_development_only",
  live_view: [signing_salt: "dev_only_signing_salt_for_local_development"],
  watchers: [
    esbuild: {Esbuild, :install_and_run, [:custyard, ~w(--sourcemap=inline --watch)]},
    tailwind: {Tailwind, :install_and_run, [:custyard, ~w(--watch)]}
  ]

config :custyard, CustyardWeb.Endpoint,
  live_reload: [
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/custyard_web/(controllers|live|components)/.*(ex|heex)$"
    ]
  ]

config :custyard, dev_routes: true

# Webhook token for development
config :custyard, :webhook_token, "dev_webhook_token"

# Allow ?as=<contact_id> param for testing contact impersonation
config :custyard, allow_contact_impersonation: true

config :logger, :console, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20

config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  debug_heex_annotations: true,
  enable_expensive_runtime_checks: true
