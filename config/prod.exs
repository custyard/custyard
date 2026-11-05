import Config

config :custyard, env: :prod, https_required: true

# The Repo is configured in config/runtime.exs, which picks the SQLite file
# or Turso at boot. A database path here would survive into the Turso config.

# Health check path accessible over plain HTTP for Fly.io machine-level probes.
# These probes bypass the proxy (no x-forwarded-proto), so Plug.SSL must skip them.
config :custyard, :health_check, path: "/api/health"

config :custyard, CustyardWeb.Endpoint,
  server: true,
  cache_static_manifest: "priv/static/cache_manifest.json"

# CustyardWeb.Proxy authenticates the origin and validates provider headers
# before SSL handling, static assets and the LiveView socket dispatch.

config :logger, level: :info
