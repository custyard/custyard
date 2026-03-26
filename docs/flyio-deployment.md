# Fly.io Deployment

Deploy Custyard to [Fly.io](https://fly.io) with SQLite persistent storage.

> **Port restrictions:** Fly.io [blocks mail server ports](https://community.fly.io/t/allow-mailserver-ports/3215) (143, 465, 587, 993). Inbound email uses the webhook endpoint at `/api/webhook/inbound` instead. See [issue #10](https://github.com/onetimesecret/custyard/issues/10) for the full email architecture.

## Prerequisites

- [Fly CLI](https://fly.io/docs/flyctl/install/) (`flyctl`)
- A Fly.io account (`fly auth signup`)

## Quick start

```bash
# From the repo root — create app + volume on Fly.io
fly launch --no-deploy

# Create a persistent volume for SQLite (pick the same region as your app)
fly volumes create custyard_data --region <your-region> --size 1

# Set required secrets
fly secrets set \
  SECRET_KEY_BASE=$(mix phx.gen.secret) \
  LIVE_VIEW_SIGNING_SALT=$(mix phx.gen.secret 32) \
  OPERATOR_PASSWORD="<GENERATE_A_STRONG_PASSWORD>"

# Deploy
fly deploy
```

> `fly launch --no-deploy` reads the existing `fly.toml`. Accept the defaults or change the app name/region when prompted. See [fly launch docs](https://fly.io/docs/launch/create/).

## Configuration

### fly.toml

The included `fly.toml` is pre-configured with:

| Setting | Value | Notes |
|---------|-------|-------|
| `primary_region` | `iad` | Change to your preferred [region](https://fly.io/docs/reference/regions/) |
| `auto_stop_machines` | `stop` | Saves cost; machines restart on traffic |
| `min_machines_running` | `1` | Keeps one machine warm for WebSocket (LiveView) |
| `mounts` | `/data` | SQLite database lives here |

Edit `PHX_HOST` in `fly.toml` `[env]` to match your domain (or `<app-name>.fly.dev`).

### Secrets

Manage secrets with [`fly secrets`](https://fly.io/docs/apps/secrets/):

```bash
# Required
fly secrets set SECRET_KEY_BASE=$(mix phx.gen.secret)
fly secrets set LIVE_VIEW_SIGNING_SALT=$(mix phx.gen.secret 32)
fly secrets set OPERATOR_PASSWORD="..."

# Inbound webhooks/email — set to enable /api/webhook/inbound (omit to disable)
fly secrets set WEBHOOK_TOKEN="..."

# Optional — outbound email (pick one adapter)
fly secrets set MAIL_ADAPTER=sendgrid SENDGRID_API_KEY="..."
# or
fly secrets set MAIL_ADAPTER=mailgun MAILGUN_API_KEY="..." MAILGUN_DOMAIN="..."
# or
fly secrets set MAIL_ADAPTER=smtp SMTP_HOST="..." SMTP_USERNAME="..." SMTP_PASSWORD="..."

# List current secrets
fly secrets list
```

### Environment variables

Non-secret environment variables go in the `[env]` section of `fly.toml`:

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `4000` | HTTP listen port |
| `PHX_HOST` | `custyard.fly.dev` | Public hostname |
| `DATABASE_URL` | — | Connection URL for Postgres or Turso (takes precedence over `DATABASE_PATH`) |
| `DATABASE_PATH` | `/data/custyard.db` | SQLite DB path (must be on the mounted volume) |
| `POOL_SIZE` | `10` | Ecto connection pool size |
| `LMTP_ENABLED` | `false` | LMTP server (disabled — ports blocked on Fly.io) |
| `IMAP_ENABLED` | `false` | IMAP polling (disabled — ports blocked on Fly.io) |
| `UPLOAD_DIR` | `/data/uploads` | Persistent upload directory (must be on the mounted volume) |

## Health check

`GET /api/health` returns `{"status":"ok"}` with a 200 status. Fly.io uses this to verify machine readiness. Configured in `fly.toml` under `[checks.health]`.

## Deployment lifecycle

On every deploy, the container entrypoint (`entrypoint.sh`) runs:

1. Generates `SECRET_KEY_BASE` if not set (not recommended — set it as a secret)
2. Runs Ecto migrations
3. Sets up the operator account
4. Starts the Phoenix server

### Deploy commands

```bash
# Deploy latest code
fly deploy

# Deploy a specific commit/image
fly deploy --image-ref <ref>

# View deploy status
fly status

# Open the app in a browser
fly apps open

# Tail production logs
fly logs

# SSH into a running machine
fly ssh console
```

See [fly deploy docs](https://fly.io/docs/launch/deploy/).

## Custom domain

```bash
fly certs add <your-domain.com>
```

Then create a CNAME record pointing your domain to `<app-name>.fly.dev`. Update `PHX_HOST` in `fly.toml` to match. See [custom domains docs](https://fly.io/docs/networking/custom-domain/).

## Volumes and backups

SQLite data is stored on a [Fly volume](https://fly.io/docs/volumes/) mounted at `/data`. Volumes are region-specific and tied to a single machine.

```bash
# List volumes
fly volumes list

# Snapshot manually (automatic daily snapshots are enabled by default)
fly volumes snapshots list <volume-id>

# Restore from snapshot
fly volumes snapshots restore <snapshot-id> --name custyard_data
```

> **Single-node constraint:** SQLite doesn't support concurrent writes from multiple machines. Keep `min_machines_running = 1` and don't scale beyond one machine in the same region. For multi-region or multi-machine setups, migrate to PostgreSQL. See [Fly Postgres docs](https://fly.io/docs/postgres/).

## Alternate data stores

The default adapter is SQLite (`Ecto.Adapters.SQLite3`). To use a different backend, set `repo_adapter` at compile time and provide `DATABASE_URL` at runtime.

### PostgreSQL

```elixir
# config/config.exs (or config/prod.exs)
config :custyard, repo_adapter: Ecto.Adapters.Postgres
```

```bash
fly postgres create --name custyard-db
fly postgres attach custyard-db  # sets DATABASE_URL automatically
fly deploy
```

Remove the `[mounts]` section from `fly.toml` if you no longer need SQLite volumes. See [Fly Postgres docs](https://fly.io/docs/postgres/).

### Neon / Supabase

External Postgres providers work the same way — set the adapter to Postgres and provide `DATABASE_URL`:

```bash
fly secrets set DATABASE_URL="postgres://user:pass@host/db?sslmode=require"
```

### Migration notes

All migrations use standard Ecto syntax. Two caveats when moving from SQLite to Postgres:

- `:map` columns (settings table) map to `jsonb` on Postgres — works automatically
- `:text` columns storing JSON arrays (project tags) work on both — consider migrating to `{:array, :string}` on Postgres for native array support

## Troubleshooting

| Symptom | Fix |
|---------|-----|
| App won't start | Check `fly logs`; verify `SECRET_KEY_BASE` is set via `fly secrets list` |
| Health check fails | Ensure port 4000 matches `internal_port` in `fly.toml` |
| Database errors | Confirm volume is mounted: `fly ssh console -C "ls -la /data"` |
| LiveView disconnects | Verify `PHX_HOST` matches your actual domain; Fly proxy handles WebSocket upgrade automatically |
| Migration failures | SSH in and run manually: `fly ssh console -C "bin/custyard eval 'Custyard.Release.migrate()'"` |

## References

- [Fly.io Phoenix getting started](https://fly.io/docs/elixir/getting-started/)
- [Fly.io configuration reference](https://fly.io/docs/reference/configuration/)
- [Fly.io community forum](https://community.fly.io/)
- [Fly.io port restrictions](https://community.fly.io/t/allow-mailserver-ports/3215)
- [Fly.io secrets management](https://fly.io/docs/apps/secrets/)
- [Fly.io volumes](https://fly.io/docs/volumes/)
