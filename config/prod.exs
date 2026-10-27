import Config

config :custyard, env: :prod

# The Repo is configured in config/runtime.exs, which picks the SQLite file
# or Turso at boot. A database path here would survive into the Turso config.

# Health check path accessible over plain HTTP for Fly.io machine-level probes.
# These probes bypass the proxy (no x-forwarded-proto), so Plug.SSL must skip them.
config :custyard, :health_check, path: "/api/health"

config :custyard, CustyardWeb.Endpoint,
  server: true,
  cache_static_manifest: "priv/static/cache_manifest.json",
  # Force SSL, trust Fly.io proxy headers, and exclude health check path.
  # Custom exclude replaces Plug.SSL's default [hosts: ["localhost", "127.0.0.1"]],
  # so we restore it explicitly here.
  # x_forwarded_host is not trusted: see Plug.RewriteOn in endpoint.ex.
  force_ssl: [
    rewrite_on: [:x_forwarded_port, :x_forwarded_proto],
    exclude: [
      hosts: ["localhost", "127.0.0.1"],
      conn: {CustyardWeb.HealthCheck, :skip_ssl?, []}
    ]
  ]

config :logger, level: :info
