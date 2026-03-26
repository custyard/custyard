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
  pubsub_server: Custyard.PubSub,
  live_view: [signing_salt: "Ed+HmLgiLg+0Lm6jRnNF5s5tlCch/CuV"]

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

# Swoosh mailer configuration
config :custyard, Custyard.Mailer, adapter: Swoosh.Adapters.Local

# Disable Swoosh API client (we don't need the API routes)
config :swoosh, :api_client, false

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
