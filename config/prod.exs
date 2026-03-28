import Config

config :custyard, env: :prod

config :custyard, Custyard.Repo,
  database: "/data/custyard.db",
  # SQLite uses a single writer lock, so high pool sizes cause contention.
  # 5 is sufficient for most workloads; override via POOL_SIZE env var.
  pool_size: 5,
  journal_mode: :wal,
  # busy_timeout in ms - SQLite will wait this long for a write lock
  # Important for the Scoring.Recalculator which runs bulk updates
  busy_timeout: 5000

config :custyard, CustyardWeb.Endpoint,
  server: true,
  cache_static_manifest: "priv/static/cache_manifest.json",
  # Force SSL and trust Fly.io proxy headers (compile-time config required)
  force_ssl: [rewrite_on: [:x_forwarded_host, :x_forwarded_port, :x_forwarded_proto]]

config :logger, level: :info
