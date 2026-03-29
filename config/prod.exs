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

# Health check path accessible over plain HTTP for Fly.io machine-level probes.
# These probes bypass the proxy (no x-forwarded-proto), so Plug.SSL must skip them.
config :custyard, :health_check, path: "/api/health"

config :custyard, CustyardWeb.Endpoint,
  server: true,
  cache_static_manifest: "priv/static/cache_manifest.json",
  # Force SSL, trust Fly.io proxy headers, and exclude health check path
  force_ssl: [
    rewrite_on: [:x_forwarded_host, :x_forwarded_port, :x_forwarded_proto],
    exclude: [conn: {CustyardWeb.HealthCheck, :skip_ssl?, []}]
  ]

config :logger, level: :info
