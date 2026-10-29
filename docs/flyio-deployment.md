# Fly.io Deployment

Deploy Custyard to [Fly.io](https://fly.io), with its SQLite database on a persistent volume or on [Turso](#turso-libsql).

Use tenant-authenticated provider callbacks at `/api/webhook/route/:callback_token`
for hosted inbound email. Configure LMTP or IMAP channels where the installation's
network supports those transports.

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
fly secrets set MAIL_ADAPTER=lettermint LETTERMINT_PROJECT_TOKEN="..."

# Name the first installation administrator; the entrypoint creates it on boot.
# Tenant staff are provisioned separately as tenant database memberships.
fly secrets set INSTANCE_ADMIN_EMAIL=you@example.com

# Deploy
fly deploy

# After your first login, stop recreating that account on every boot
fly secrets unset INSTANCE_ADMIN_EMAIL
```

Instead of `INSTANCE_ADMIN_EMAIL` you can create the account on the running machine
with `fly ssh console -a custyard -C "/app/bin/instance-admin add you@example.com"`.
See [Instance administrators and tenant staff](#instance-administrators-and-tenant-staff).

> **System authentication mail:** Instance administrators and staff use magic links: the
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
| `min_machines_running` | `1` | Keeps one machine warm for WebSocket (LiveView). A floor, not a cap — cap the count with `fly scale count 1` |
| `mounts` | `custyard_data` at `/data` | Required for SQLite and uploads. The app refuses to start on Fly if `/data` is not mounted. |

Edit `PHX_HOST` in `fly.toml` `[env]` to match your domain (or `<app-name>.fly.dev`).

### Secrets

Manage secrets with [`fly secrets`](https://fly.io/docs/apps/secrets/):

```bash
# Required (deployment will fail without SECRET_KEY_BASE)
fly secrets set SECRET_KEY_BASE=$(mix phx.gen.secret)

# Required — outbound email (pick one adapter; the app refuses to boot
# without MAIL_ADAPTER, because operator login is magic-link-only)
fly secrets set MAIL_ADAPTER=lettermint LETTERMINT_PROJECT_TOKEN="..." LETTERMINT_API_URL="..."
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

# Optional: the database on Turso instead of the volume. See Turso below.
fly secrets set DATABASE_URL="libsql://custyard-<org>.turso.io" TURSO_AUTH_TOKEN="..."

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
| `DATABASE_URL` | — | A Turso `libsql://` URL (with the `TURSO_AUTH_TOKEN` secret), or a PostgreSQL URL when the release was compiled with `Ecto.Adapters.Postgres`. Unset: the SQLite file at `DATABASE_PATH` |
| `DATABASE_PATH` | `/data/custyard.db` | SQLite DB path (must be on the mounted volume); unused when `DATABASE_URL` is set |
| `MAIL_ADAPTER` | — | **Required.** One of `lettermint`, `postmark`, `sendgrid`, `mailgun`, `smtp`, `local`. Set as a secret alongside its credential; the app raises on boot if unset or unrecognized |
| `POOL_SIZE` | `10` | Ecto connection pool size |
| `LMTP_ENABLED` | `false` | LMTP server (disabled — ports blocked on Fly.io) |
| `UPLOAD_DIR` | `/data/uploads` | Persistent upload directory (must be on the mounted volume) |
| `ATTACHMENT_DIR` | `/data/attachments` | Inbound email attachments, served only through the authenticated operator endpoint (must be on the mounted volume) |

`CREDENTIAL_ENCRYPTION_KEY` is a secret (`fly secrets set CREDENTIAL_ENCRYPTION_KEY="$(openssl rand -base64 32)"`). IMAP channels need it to store their passwords; see [inbound channels](ops/inbound-channels.md#credential-encryption-key). The global `IMAP_*` settings were removed, and a deployment that still sets `IMAP_ENABLED` refuses to start.

## Colonel acknowledgments

Each tenant configures its own encrypted broker credential, source and queue
at `/app/settings/integrations`. `CREDENTIAL_ENCRYPTION_KEY` must be set before
storing the credential. Enabled active tenants have independent consumers;
suspension stops their consumers. `ACKNOWLEDGMENTS_PREFETCH` controls process
concurrency, while subscription identity and credentials remain database settings.

```bash
fly ssh console -a custyard -C "/app/bin/acknowledgments status --tenant 7"
```

Provision the broker queues and bind source organizations to customers before
enabling publication. See [Operating Colonel acknowledgments](ops/acknowledgments.md)
for tenant configuration, TLS, permissions and the command set.

## Health check

`GET /api/health` returns `{"status":"ok"}` with a 200 status. Fly.io uses this to verify machine readiness. Configured in `fly.toml` under `[checks.health]`.

S󠄁e󠄁t󠄁 t󠄁h󠄁e󠄁 c󠄁h󠄁e󠄁c󠄁k󠄁'󠄁s󠄁 `headers.Host` t󠄁o󠄁 t󠄁h󠄁e󠄁 i󠄁n󠄁s󠄁t󠄁a󠄁l󠄁l󠄁a󠄁t󠄁i󠄁o󠄁n󠄁'󠄁s󠄁 `PHX_HOST`.󠄁 T󠄁e󠄁n󠄁a󠄁n󠄁t󠄁 h󠄁o󠄁s󠄁t󠄁
v󠄁a󠄁l󠄁i󠄁d󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 a󠄁l󠄁s󠄁o󠄁 a󠄁p󠄁p󠄁l󠄁i󠄁e󠄁s󠄁 t󠄁o󠄁 h󠄁e󠄁a󠄁l󠄁t󠄁h󠄁 r󠄁e󠄁q󠄁u󠄁e󠄁s󠄁t󠄁s󠄁;󠄁 a󠄁 p󠄁r󠄁o󠄁b󠄁e󠄁 s󠄁e󠄁n󠄁t󠄁 t󠄁o󠄁 a󠄁n󠄁 u󠄁n󠄁r󠄁e󠄁g󠄁i󠄁s󠄁t󠄁e󠄁r󠄁e󠄁d󠄁 I󠄁P󠄁
o󠄁r󠄁 h󠄁o󠄁s󠄁t󠄁n󠄁a󠄁m󠄁e󠄁 r󠄁e󠄁c󠄁e󠄁i󠄁v󠄁e󠄁s󠄁 4󠄁0󠄁4󠄁.󠄁 T󠄁h󠄁e󠄁 c󠄁o󠄁n󠄁t󠄁a󠄁i󠄁n󠄁e󠄁r󠄁 h󠄁e󠄁a󠄁l󠄁t󠄁h󠄁 c󠄁h󠄁e󠄁c󠄁k󠄁 u󠄁s󠄁e󠄁s󠄁 `PHX_HOST` t󠄁o󠄁o󠄁.󠄁

## Deployment lifecycle

On every deploy, the container entrypoint (`entrypoint.sh`) runs:

1. Validates `SECRET_KEY_BASE` is set (fails fast if missing)
2. Runs Ecto migrations
3. With `INSTANCE_ADMIN_EMAIL` set, creates that installation administrator if
   absent and logs a reminder to unset the variable. Existing accounts remain
   unchanged. Invalid email input fails bootstrap. No implicit administrator,
   tenant, staff membership or support connection is created. Migration and
   bootstrap run in one database-only `bin/custyard eval`.
4. Starts the Phoenix server

With `MAINTENANCE_MODE=true` it does none of this and keeps the machine running
for `fly ssh`, so nothing writes the database. Moving SQLite to Turso uses it
(`docs/ops/database.md`).

> **Important:** `SECRET_KEY_BASE` must be set via `fly secrets set` before deploying. The entrypoint will refuse to start without it. This prevents session/LiveView invalidation when machines restart (which happens regularly with `auto_stop_machines`).

### Deploy commands

```bash
# Deploy latest code ()
fly deploy

# Migrations are run automatically by the entrypoint, but you can also run them
# manually. Run as custyard: `fly ssh console` is root, and root-owned SQLite
# -wal/-shm files would leave the app with a read-only database.
# fly ssh console -a custyard -C "runuser -u custyard -- /app/bin/custyard eval 'Custyard.Release.migrate()'"

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

Erlang distribution is off (`RELEASE_DISTRIBUTION=none` in `rel/env.sh.eex`), so
`bin/custyard remote` and `bin/custyard rpc` do not work. Use `bin/instance-admin` for
accounts, `bin/dsar` for data subject requests, or `bin/custyard eval` for
one-off code: it runs in a separate VM with the app's configuration and does not
start the app. Anything that writes the database must run as `custyard`
(`bin/instance-admin` and `bin/dsar` switch user themselves).

## Instance administrators and tenant staff

The installation console uses `/admin/login` on the configured installation
host. Its header shows **Instance admin** and the signed-in email. The
database-only CLI manages these installation identities:

```bash
fly ssh console -a custyard -C "/app/bin/instance-admin add installer@example.com"
fly ssh console -a custyard -C "/app/bin/instance-admin list"
fly ssh console -a custyard -C "/app/bin/instance-admin remove installer@example.com"
fly ssh console -a custyard -C "/app/bin/instance-admin help"
```

The CLI refuses to remove the last installation administrator. Bootstrap
identity comes from `INSTANCE_ADMIN_EMAIL`, never an email-domain rule. Unset
the variable after bootstrap to stop recreating that identity on future boots.
Account creation/removal is audited and session claims prevent removed
identities from retaining access when IDs are reused.

Create tenants, register hostnames and provision their first staff admin through
`/admin`. A tenant can explicitly claim the installation hostname; wildcard DNS
is optional. Staff sign in at `/app/login` on their tenant's hostname. The header
shows the tenant name, **Staff** and the signed-in email. Staff roles are admin
or agent; memberships are tenant database records. Instance administration does
not grant membership or access to customer data.

Tenant admins manage staff at `/app/settings/workspace` and configure support
mail at `/app/settings/email`. Installation mail configuration handles login
mail independently of these tenant provider credentials.

## Data subject requests

`bin/dsar` exports or erases what one email address appears on in one
organization: as sender, To, CC or Reply-To. Like `bin/instance-admin`, it starts only
the database (never the app), so it is safe while the server runs. `ID` is the
organization's i󠄁n󠄁t󠄁e󠄁r󠄁n󠄁a󠄁l󠄁 d󠄁a󠄁t󠄁a󠄁b󠄁a󠄁s󠄁e󠄁 n󠄁u󠄁m󠄁b󠄁e󠄁r󠄁.󠄁 C󠄁u󠄁s󠄁t󠄁o󠄁m󠄁e󠄁r󠄁 U󠄁R󠄁L󠄁s󠄁 u󠄁s󠄁e󠄁 a󠄁 s󠄁e󠄁p󠄁a󠄁r󠄁a󠄁t󠄁e󠄁 o󠄁p󠄁a󠄁q󠄁u󠄁e󠄁
p󠄁u󠄁b󠄁l󠄁i󠄁c󠄁 i󠄁d󠄁e󠄁n󠄁t󠄁i󠄁f󠄁i󠄁e󠄁r󠄁;󠄁 d󠄁o󠄁 n󠄁o󠄁t󠄁 p󠄁a󠄁s󠄁s󠄁 t󠄁h󠄁e󠄁 U󠄁R󠄁L󠄁 i󠄁d󠄁e󠄁n󠄁t󠄁i󠄁f󠄁i󠄁e󠄁r󠄁 t󠄁o󠄁 `--org`.󠄁

```bash
# Every message the address appears on, as JSON on stdout; the body only for
# messages the person sent
fly ssh console -a custyard -C "runuser -u custyard -- /app/bin/dsar export pat@example.com --org 3"

# Remove the address from recipient lists and Reply-To on messages the person
# did not send; reports how many messages they sent
fly ssh console -a custyard -C "runuser -u custyard -- /app/bin/dsar erase pat@example.com --org 3 --yes"

# The same, plus the messages the person sent (tombstoned and emptied), their
# attachments, contact record, thread subjects and rejection-log entries
fly ssh console -a custyard -C "runuser -u custyard -- /app/bin/dsar erase-contact pat@example.com --org 3 --yes"

fly ssh console -a custyard -C "runuser -u custyard -- /app/bin/dsar help"
```

- Erasures are irreversible and refuse to run without `--yes`. An invalid
  address, a missing, repeated or unknown `--org`, or any other usage error
  exits 1 before the database is opened.
- Every erasure writes a `data_subject_erasure` audit event with counts only.
  Neither the audit event nor an error message contains the address.
- Erasure is scoped to the selected customer and tenant. Linked prospect
  credentials, personal customer identities and claim-email data are scrubbed;
  unrelated customers and tenants remain intact.
- In development the same actions are `mix custyard.dsar ...`.

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

> **Single-node constraint:** a Fly volume attaches to exactly one machine, so
> every extra machine gets its own volume with its own SQLite database, uploads
> and inbound attachments. Two machines means two copies that diverge silently:
> writes land on whichever machine the proxy picked, an attachment stored on one
> machine is a 404 on the other, and the app keeps reporting healthy.
>
> `min_machines_running = 1` does not prevent this. It is a floor on how many
> machines stay warm, not a cap on how many exist. Enforce the cap explicitly:
>
> ```sh
> fly scale count 1 -a custyard   # verify with: fly scale show -a custyard
> ```
>
> Check `fly scale show` before every deploy that touches `[mounts]`. A deploy
> that introduces a mount while the app has two machines creates a second
> volume and splits the data. The app refuses to boot when it has more than
> one machine and keeps anything under `/data` (`Custyard.Storage`), but the
> refusal is a backstop, not a substitute for the scale check.
>
> Turso and PostgreSQL do not lift this limit. Uploads and attachments are still files
> under `/data`, so each machine's volume holds its own copy.

## Alternate data stores

The default adapter, `Custyard.Repo.Adapter`, is SQLite: the file on the volume, or Turso when `DATABASE_URL` is a `libsql://` URL. The same release serves both. PostgreSQL needs `repo_adapter` set at compile time and `DATABASE_URL` at runtime.

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

Keep the `[mounts]` section: uploads and attachments still use `/data`, so the app stays on one machine (see [Volumes and backups](#volumes-and-backups)). See [Fly Postgres docs](https://fly.io/docs/postgres/).

### Turso (libSQL)

Set `DATABASE_URL` to the database's `libsql://` URL and `TURSO_AUTH_TOKEN` to
a token for it; no rebuild is needed:

```bash
turso db create custyard              # or --from-file, to bring the SQLite data
turso db show custyard --url
turso db tokens create custyard
fly secrets set DATABASE_URL="libsql://custyard-<org>.turso.io" TURSO_AUTH_TOKEN="..."
```

Keep the volume and `[mounts]`: uploads and inbound attachments are still files
under `/data`, and the app still runs on one machine. Moving an existing
database, the limits, and rollback are in
[Database operations](ops/database.md#turso).

Before this release, a `libsql://` `DATABASE_URL` never reached Turso: the
SQLite driver treated it as a local file name. If `.env.secrets` still has
such a line, `mix fly.secrets --apply` now switches the app to that Turso
database. Check the file first.

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
| `Turso: HTTP 401` in `fly logs` | `TURSO_AUTH_TOKEN` is wrong or expired. Create one with `turso db tokens create custyard` and `fly secrets set TURSO_AUTH_TOKEN=...` |
| LiveView disconnects | Verify `PHX_HOST` matches your actual domain; Fly proxy handles WebSocket upgrade automatically |
| Migration failures | Run manually as the app user: `fly ssh console -a custyard -C "runuser -u custyard -- /app/bin/custyard eval 'Custyard.Release.migrate()'"` |
| Nobody can log in | `fly ssh console -a custyard -C "/app/bin/instance-admin list"`; create an account with `/app/bin/instance-admin add you@example.com` or `fly secrets set INSTANCE_ADMIN_EMAIL=you@example.com` and redeploy |
| Login link never arrives | The "check your email" page is shown even for unknown addresses. Confirm the account with `/app/bin/instance-admin list`, then check `MAIL_ADAPTER` and `fly logs` |
| Boot fails with `INSTANCE_ADMIN_EMAIL: ...` | The value is not a valid address. Fix or unset it: `fly secrets unset INSTANCE_ADMIN_EMAIL` |
| Database becomes read-only after an SSH session | Something wrote the database as root. Run app commands as `custyard` (`bin/instance-admin` does). Assuming the default `DATABASE_PATH`, run `chown custyard:custyard /data/custyard.db*`, then restart the app (`fly apps restart custyard`) |
| `bin/custyard remote` or `rpc` fails | Erlang distribution is off. Use `/app/bin/instance-admin` or `bin/custyard eval` |

## References

- [Fly.io Phoenix getting started](https://fly.io/docs/elixir/getting-started/)
- [Fly.io configuration reference](https://fly.io/docs/reference/configuration/)
- [Fly.io community forum](https://community.fly.io/)
- [Fly.io port restrictions](https://community.fly.io/t/allow-mailserver-ports/3215)
- [Fly.io secrets management](https://fly.io/docs/apps/secrets/)
- [Fly.io volumes](https://fly.io/docs/volumes/)
