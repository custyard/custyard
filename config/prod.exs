import Config

config :custyard, env: :prod

config :custyard, Custyard.Repo,
  database: "/data/custyard.db",
  pool_size: 10

config :custyard, CustyardWeb.Endpoint,
  server: true,
  cache_static_manifest: "priv/static/cache_manifest.json"

config :logger, level: :info
