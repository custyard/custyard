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

# Create a persistent volume before deploying. The shipped fly.toml mounts it
# at /data for both SQLite and uploaded files.
fly volumes create custyard_data --region <your-region> --size 1

# Set required secrets (deployment fails without these)
fly secrets set SECRET_KEY_BASE=$(mix phx.gen.secret)
fly secrets set MAIL_ADAPTER=lettermint LETTERMINT_API_KEY="..."

# Deploy
fly deploy

# Create a routable operator — bootstrap only seeds the non-routable
# admin@custyard.local, and login is magic-link-only, so without this
# nobody can sign in.
fly ssh console -C "/app/bin/custyard eval 'Custyard.Release.setup_operator(\"you@yourdomain\")'"
```

> **Mail is required, not optional.** Operator login is magic-link-only: the
> app emails a single-use token and there is no password path. `config/runtime.exs`
> refuses to boot if `MAIL_ADAPTER` is unset or unrecognized, which surfaces the
> problem at deploy time while Fly still has the previous machine running. Use
> `MAIL_ADAPTER=local` only for a smoke-test instance — it discards every message,
> including your own login links.

> `fly launch --no-deploy` reads the existing `fly.toml`. Accept the defaults or change the app name/region when prompted. See [fly launch docs](https://fly.io/docs/launch/create/).

## Configuration

### fly.toml

The included `fly.toml` is pre-configured with:

| Setting | Value | Notes |
|---------|-------|-------|
| `primary_region` | `ams` | Change to your preferred [region](https://fly.io/docs/reference/regions/) |
| `auto_stop_machines` | `stop` | Saves cost; machines restart on traffic |
| `min_machines_running` | `1` | Keeps one machine warm for WebSocket (LiveView) |
| `mounts` | `custyard_data` at `/data` | Required for SQLite and uploads. The app refuses to start on Fly if `/data` is not mounted. |

Edit `PHX_HOST` in `fly.toml` `[env]` to match your domain (or `<app-name>.fly.dev`).

### Secrets

Manage secrets with [`fly secrets`](https://fly.io/docs/apps/secrets/):

```bash
# Required (deployment will fail without SECRET_KEY_BASE)
fly secrets set SECRET_KEY_BASE=$(mix phx.gen.secret)

# Required — outbound email (pick one adapter; the app refuses to boot
# without MAIL_ADAPTER, because operator login is magic-link-only)
fly secrets set MAIL_ADAPTER=lettermint LETTERMINT_API_KEY="..." LETTERMINT_API_URL="..."
# or
fly secrets set MAIL_ADAPTER=postmark POSTMARK_API_KEY="..."
# or
fly secrets set MAIL_ADAPTER=sendgrid SENDGRID_API_KEY="..."
# or
fly secrets set MAIL_ADAPTER=mailgun MAILGUN_API_KEY="..." MAILGUN_DOMAIN="..."
# or
fly secrets set MAIL_ADAPTER=smtp SMTP_HOST="..." SMTP_USERNAME="..." SMTP_PASSWORD="..."
# or, smoke-test instances only — discards all mail including login links
fly secrets set MAIL_ADAPTER=local

# Optional (derived from SECRET_KEY_BASE if not set)
fly secrets set LIVE_VIEW_SIGNING_SALT=$(mix phx.gen.secret 32)

# Optional — inbound webhook signature verification, one secret per source.
# Omit a source to leave its signature check unconfigured.
fly secrets set WEBHOOK_SECRET_LETTERMINT="..."
fly secrets set WEBHOOK_SECRET_ZENDESK="..."
fly secrets set WEBHOOK_SECRET_INTERCOM="..."
fly secrets set WEBHOOK_SECRET_SLACK="..."

# Optional — error tracking (prod only; unset means the Sentry SDK stays off)
fly secrets set SENTRY_DSN="https://<public_key>@catch.onetimesecret.com/11"

# List current secrets
fly secrets list
```

These are synced from `.env.secrets` by `mix fly.secrets --apply`. That task
skips any line beginning with `#`, so a key that is present-but-commented in
`.env.secrets` is never set on Fly — check `fly secrets list` rather than
assuming the file is the source of truth.

### Environment variables

Non-secret environment variables go in the `[env]` section of `fly.toml`:

| Variable | Default | Description |
|----------|---------|-------------|
| `PORT` | `4000` | HTTP listen port |
| `PHX_HOST` | `custyard.fly.dev` | Public hostname |
| `DATABASE_URL` | — | PostgreSQL URL only when the release was compiled with `Ecto.Adapters.Postgres`. `libsql://` is rejected. |
| `DATABASE_PATH` | `/data/custyard.db` | SQLite DB path (must be on the mounted volume) |
| `MAIL_ADAPTER` | — | **Required.** One of `lettermint`, `postmark`, `sendgrid`, `mailgun`, `smtp`, `local`. Set as a secret alongside its credential; the app raises on boot if unset or unrecognized |
| `POOL_SIZE` | `10` | Ecto connection pool size |
| `LMTP_ENABLED` | `false` | LMTP server (disabled — ports blocked on Fly.io) |
| `IMAP_ENABLED` | `false` | IMAP polling (disabled — ports blocked on Fly.io) |
| `UPLOAD_DIR` | `/data/uploads` | Persistent upload directory (must be on the mounted volume) |

## Health check

`GET /api/health` returns `{"status":"ok"}` with a 200 status. Fly.io uses this to verify machine readiness. Configured in `fly.toml` under `[checks.health]`.

## Deployment lifecycle

On every deploy, the container entrypoint (`entrypoint.sh`) runs:

1. Validates `SECRET_KEY_BASE` is set (fails fast if missing)
2. Runs Ecto migrations
3. Sets up the operator account
4. Starts the Phoenix server

> **Important:** `SECRET_KEY_BASE` must be set via `fly secrets set` before deploying. The entrypoint will refuse to start without it. This prevents session/LiveView invalidation when machines restart (which happens regularly with `auto_stop_machines`).

### Deploy commands

```bash
# Deploy latest code ()
fly deploy

# Migrations are run automatically by the entrypoint, but you can also run them manually:
# fly ssh console -C "bin/custyard eval 'Custyard.Release.migrate()'"

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

https://fly.io/apps/custyard/monitoring

https://custyard.fly.dev/

See [fly deploy docs](https://fly.io/docs/launch/deploy/).

## Custom domain

```bash
fly certs add <your-domain.com>
```

Then create a CNAME record pointing your domain to `<app-name>.fly.dev`. Update `PHX_HOST` in `fly.toml` to match. See [custom domains docs](https://fly.io/docs/networking/custom-domain/).

## Volumes and backups

SQLite data and uploads are stored on a [Fly volume](https://fly.io/docs/volumes/) mounted at `/data`. Volumes are region-specific and tied to a single machine. Before migrations run, the app checks the Linux mount table and refuses to start if Fly has not mounted `/data`.

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

Keep the `[mounts]` section if uploads still use `/data/uploads`. See [Fly Postgres docs](https://fly.io/docs/postgres/).

### Turso (libSQL)

This release does not support Turso. `Ecto.Adapters.SQLite3` and its locked Exqlite driver treat a `libsql://` URL as a local filename, so runtime configuration now rejects that URL at startup. Moving to Turso requires a compatible Ecto adapter and a migration plan for the existing SQLite data.

If an existing Fly app was configured with `DATABASE_URL=libsql://...`, inspect and back up its current machine **before** removing that secret or deploying this change. The previous driver may have stored data in a local `libsql:/...` path inside the container. That data is not automatically copied to `/data`, and replacing the machine can remove it. Restore any recoverable data onto the mounted volume, then confirm `/data/custyard.db` contains the expected records before switching traffic.

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
| "ERROR: SECRET_KEY_BASE is not set" | Run `fly secrets set SECRET_KEY_BASE=$(mix phx.gen.secret)` |
| App won't start | Check `fly logs`; verify `SECRET_KEY_BASE` is set via `fly secrets list` |
| Health check fails | Ensure port 4000 matches `internal_port` in `fly.toml` |
| Database errors | Confirm the volume is attached with `fly volumes list` and mounted with `fly ssh console -C "mountpoint /data"` |
| LiveView disconnects | Verify `PHX_HOST` matches your actual domain; Fly proxy handles WebSocket upgrade automatically |
| Migration failures | SSH in and run manually: `fly ssh console -C "bin/custyard eval 'Custyard.Release.migrate()'"` |

## References

- [Fly.io Phoenix getting started](https://fly.io/docs/elixir/getting-started/)
- [Fly.io configuration reference](https://fly.io/docs/reference/configuration/)
- [Fly.io community forum](https://community.fly.io/)
- [Fly.io port restrictions](https://community.fly.io/t/allow-mailserver-ports/3215)
- [Fly.io secrets management](https://fly.io/docs/apps/secrets/)
- [Fly.io volumes](https://fly.io/docs/volumes/)
