import Config

config :custyard,
  ecto_repos: [Custyard.Repo],
  generators: [timestamp_type: :utc_datetime]

config :custyard, CustyardWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: CustyardWeb.ErrorHTML, json: CustyardWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Custyard.PubSub,
  live_view: [signing_salt: "custyard_lv_salt"]

config :esbuild,
  version: "0.17.11",
  custyard: [
    args:
      ~w(js/app.js --bundle --target=es2017 --outdir=../priv/static/assets --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

config :tailwind,
  version: "3.4.0",
  custyard: [
    args: ~w(
      --config=tailwind.config.js
      --input=css/app.css
      --output=../priv/static/assets/app.css
    ),
    cd: Path.expand("../assets", __DIR__)
  ]

config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

# Swoosh mailer configuration
config :custyard, Custyard.Mailer, adapter: Swoosh.Adapters.Local

# Disable Swoosh API client (we don't need the API routes)
config :swoosh, :api_client, false

# LMTP server configuration (for receiving emails from MTA)
config :custyard, :lmtp,
  enabled: false,
  port: 2024,
  hostname: "localhost"

import_config "#{config_env()}.exs"
