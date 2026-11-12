# Fly.io Deployment

Deploy Custyard to [Fly.io](https://fly.io), with its SQLite database on a persistent volume or on [Turso](#turso-libsql). Uploaded logos and email attachments are stored in the database, so the volume is needed only for a local SQLite file.

For the proposed move of production to Bunny Magic Containers and conversion of
Fly to `staging.custyard.com`, see the [migration plan](ops/bunny-production-fly-staging.md).
The configuration in this guide still describes Fly hosting; the migration has
not been applied.

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
# at /data for the SQLite database, which also holds uploaded files.
fly volumes create custyard_data --region <your-region> --size 1

# Set the required secrets. Without them the app boots into a doctor card
# that names what is missing (see "Deployment lifecycle").
fly secrets set SECRET_KEY_BASE=$(mix phx.gen.secret)
fly secrets set CREDENTIAL_ENCRYPTION_KEY=$(openssl rand -base64 32)
fly secrets set MAIL_ADAPTER=lettermint LETTERMINT_PROJECT_TOKEN="..."

# Name the first installation administrator; the app creates it on the next boot.
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

> **Mail is required, not optional.** Instance administrators and staff sign in
> by magic link: the app emails a single-use token and there is no password
> path. With `MAIL_ADAPTER` unset or unrecognized the app boots into the doctor
> card and stays there; the Fly health check is liveness only, so the deploy
> still reports healthy. Open the site or read the boot report in `fly logs`
> after every deploy. Use `MAIL_ADAPTER=local` only for a smoke-test instance —
> it discards every message, including your own login links.

> `fly launch --no-deploy` reads the existing `fly.toml`. Accept the defaults or change the app name/region when prompted. See [fly launch docs](https://fly.io/docs/launch/create/).

## Configuration

### fly.toml

The included `fly.toml` is pre-configured with:

| Setting | Value | Notes |
|---------|-------|-------|
| `primary_region` | `ams` | Change to your preferred [region](https://fly.io/docs/reference/regions/) |
| `auto_stop_machines` | `stop` | Saves cost; machines restart on traffic |
| `min_machines_running` | `1` | Keeps one machine warm for WebSocket (LiveView). A floor, not a cap — cap the count with `fly scale count 1` |
| `mounts` | `custyard_data` at `/data` | Required while the database is the local SQLite file. With `/data` not mounted the boot probe reports it and the app serves the database card. Not needed with a remote database. |

Edit `PHX_HOST` in `fly.toml` `[env]` to match your domain (or `<app-name>.fly.dev`).

### Secrets

Manage secrets with [`fly secrets`](https://fly.io/docs/apps/secrets/):

```bash
# Required: without these the app serves the doctor card instead of the site
fly secrets set SECRET_KEY_BASE=$(mix phx.gen.secret)
fly secrets set CREDENTIAL_ENCRYPTION_KEY=$(openssl rand -base64 32)

# Required — outbound email (pick one adapter; the doctor card names
# MAIL_ADAPTER as missing otherwise, because login is magic-link-only)
fly secrets set MAIL_ADAPTER=lettermint LETTERMINT_PROJECT_TOKEN="..."
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

# Inbound webhook signing secrets are not environment settings: each tenant
# route stores its own, encrypted, in Email setup.

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
| `MAIL_ADAPTER` | — | **Required.** One of `lettermint`, `postmark`, `sendgrid`, `mailgun`, `smtp`, `local`. Set as a secret alongside its credential; unset or unrecognized is a doctor-card problem |
| `POOL_SIZE` | `10` | Ecto connection pool size |
| `LMTP_ENABLED` | `false` | LMTP server (disabled — ports blocked on Fly.io) |
| `UPLOAD_DIR` | `/data/uploads` | Where an earlier release wrote tenant logos. Read only by the import of those files into the database; leave unset on a new install |
| `ATTACHMENT_DIR` | `/data/attachments` | Where an earlier release wrote inbound email attachments. Read only by the same import; leave unset on a new install |

Logos and attachments are stored in the database and served from it. See
[Files in the database](ops/database.md#files-in-the-database) for the
variables above and for upgrading an app whose files are still on the volume.

`CREDENTIAL_ENCRYPTION_KEY` is a required secret (`fly secrets set CREDENTIAL_ENCRYPTION_KEY="$(openssl rand -base64 32)"`): every boot checks it, and tenant credentials (IMAP passwords, Lettermint tokens) are encrypted with it; see [inbound channels](ops/inbound-channels.md#credential-encryption-key). The global `IMAP_*` settings were removed, and a deployment that still sets `IMAP_ENABLED` gets a doctor-card problem.

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

`GET /api/health` returns `{"status":"ok"}` with a 200 status once the app is fully up, and 503 while it is in doctor mode (configuration or database problem). Fly's machine check in `fly.toml` under `[checks.health]` uses `GET /api/health/live`, which answers 200 whenever the process is up, so a machine in doctor mode keeps serving its setup page.

Set the check's `headers.Host` to the installation's `PHX_HOST`. Tenant host
validation also applies to health requests; a probe sent to an unregistered IP
or hostname receives 404. The container health check uses `PHX_HOST` too.

## Deployment lifecycle

The container entrypoint (`entrypoint.sh`) only hands off to the release; the
application does the rest on every boot:

1. Reads and checks the environment. With variables missing or malformed it
   stays up and serves a doctor card at every HTML path (HTTP 503) naming
   them, prints the same report to `fly logs`, and waits for a restart.
2. Starts the HTTP endpoint, so `/api/health/live` answers, then probes the
   database and runs the Ecto migrations one at a time. An unreachable
   database is a database card with retries every 10 s; a failed migration
   names the migration and does not retry.
3. With `INSTANCE_ADMIN_EMAIL` set, creates that installation administrator if
   it does not exist (an existing account is left unmodified), sends the
   welcome mail through the real adapter, and shows the setup checklist on
   `/` for the rest of that boot. No tenant, staff membership or support
   connection is created implicitly. Unset the variable after the first login.
4. When rows still refer to logos or attachments that an earlier release
   left on the volume, copies them into the database in the background.
   Nothing waits for it; see
   [Upgrading from a release that kept files on disk](ops/database.md#upgrading-from-a-release-that-kept-files-on-disk).

`bin/doctor` prints the same report from `fly ssh console`, with
`--probe-database` to connect as well. With `MAINTENANCE_MODE=true` the
entrypoint does none of this and keeps the machine running for `fly ssh`, so
nothing writes the database. Moving SQLite to Turso uses it
(`docs/ops/database.md`).

> **Important:** set `SECRET_KEY_BASE` with `fly secrets set` before deploying.
> Without it the app serves the doctor card, and a value that changes between
> deploys invalidates every session and LiveView (machines restart regularly
> with `auto_stop_machines`).

### Deploy commands

```bash
# Deploy latest code ()
fly deploy

# Migrations run automatically on boot, but you can also run them
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
`/admin`. The installation hostname is reserved; every tenant needs a distinct
workspace hostname. Wildcard DNS is optional. Staff sign in at `/app/login` on their tenant's hostname. The header
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
organization's internal database number. Customer URLs use a separate opaque
public identifier; do not pass the URL identifier to `--org`.

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

The SQLite database is stored on a [Fly volume](https://fly.io/docs/volumes/) mounted at `/data`. Uploaded logos and attachments are inside the database, so a copy of it includes them. Volumes are region-specific and tied to a single machine. Before migrations run, the app checks the Linux mount table; if Fly has not mounted `/data` it serves the database card instead of writing to the root filesystem. With a remote database nothing is stored on a volume and the mount is not checked; an app that moved from SQLite, or that still has files on disk from an earlier release, can drop its volume as described in [Removing the volume](ops/database.md#removing-the-volume).

```bash
# List volumes
fly volumes list

# Snapshot manually (automatic daily snapshots are enabled by default)
fly volumes snapshots list <volume-id>

# Restore into a new volume (preserve the source during a drill)
fly volumes create custyard_restore --snapshot-id <snapshot-id> --region <region> --size <GB>
```

Use the [backup and restore drill](ops/backup-restore.md) to verify the database
and the files stored in it without starting mail delivery.

> **Single-node constraint:** a Fly volume attaches to exactly one machine, so
> every extra machine gets its own volume with its own SQLite database, files
> included. Two machines means two copies that diverge silently:
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
> volume and splits the data. The app serves the database card when it has
> more than one machine and a local SQLite database (`Custyard.Storage`),
> but that is a backstop, not a substitute for the scale check.
>
> A remote database (Turso, Bunny Database or PostgreSQL) is not subject to
> this check: files are stored in the database, so every machine reads the same
> ones, and no volume is needed. Nothing else about running more than one
> machine has been tested; see [Limits](ops/database.md#limits).

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

With PostgreSQL the app expects no volume: uploaded files are stored in the database. Remove the `[mounts]` section for a new app. An app that already has files on its volume keeps the mount until the import has finished (see [Removing the volume](ops/database.md#removing-the-volume)). CI runs the file store on SQLite and libSQL only, so check a logo upload and an attachment download on a PostgreSQL build before relying on it. See [Fly Postgres docs](https://fly.io/docs/postgres/).

### Turso (libSQL)

Set `DATABASE_URL` to the database's `libsql://` URL and `TURSO_AUTH_TOKEN` to
a token for it; no rebuild is needed:

```bash
turso db create custyard              # or --from-file, to bring the SQLite data
turso db show custyard --url
turso db tokens create custyard
fly secrets set DATABASE_URL="libsql://custyard-<org>.turso.io" TURSO_AUTH_TOKEN="..."
```

A new app on Turso needs no volume: remove the `[mounts]` section from
`fly.toml` and skip `fly volumes create`. An app moving from SQLite keeps the
volume and `[mounts]` until the old database file is no longer wanted as a way
back and the import of files from an earlier release reports nothing pending
([Removing the volume](ops/database.md#removing-the-volume)). Moving an
existing database, the limits, and rollback are in
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
| Every page is a doctor card (HTTP 503) | The card and the top of `fly logs` name the missing or malformed variables; `fly ssh console -a custyard -C /app/bin/doctor` prints the same report. Set them and `fly apps restart custyard` |
| App won't start | Check `fly logs`; the boot report at the top names configuration problems, and `/api/health/live` answers whenever the process is up |
| Health check fails | Ensure port 4000 matches `internal_port` in `fly.toml` |
| Database errors | With local SQLite, confirm the volume is attached with `fly volumes list` and mounted with `fly ssh console -C "mountpoint /data"` |
| A logo or an older attachment answers 404 after an upgrade | It has not been copied from the volume into the database. Run `fly ssh console -C "runuser -u custyard -- /app/bin/custyard eval 'Custyard.Release.import_legacy_files()'"` and read `pending`, `missing` and `failed` ([Database operations](ops/database.md#upgrading-from-a-release-that-kept-files-on-disk)) |
| `Turso: HTTP 401` in `fly logs` | `TURSO_AUTH_TOKEN` is wrong or expired. Create one with `turso db tokens create custyard` and `fly secrets set TURSO_AUTH_TOKEN=...` |
| LiveView disconnects | Verify `PHX_HOST` matches your actual domain; Fly proxy handles WebSocket upgrade automatically |
| Migration failures | Run manually as the app user: `fly ssh console -a custyard -C "runuser -u custyard -- /app/bin/custyard eval 'Custyard.Release.migrate()'"` |
| Nobody can log in | `fly ssh console -a custyard -C "/app/bin/instance-admin list"`; create an account with `/app/bin/instance-admin add you@example.com` or `fly secrets set INSTANCE_ADMIN_EMAIL=you@example.com` and redeploy |
| Login link never arrives | The "check your email" page is shown even for unknown addresses. Confirm the account with `/app/bin/instance-admin list`, then check `MAIL_ADAPTER` and `fly logs` |
| Doctor card names `INSTANCE_ADMIN_EMAIL` | The value is not a valid address. Fix or unset it: `fly secrets unset INSTANCE_ADMIN_EMAIL` |
| Database becomes read-only after an SSH session | Something wrote the database as root. Run app commands as `custyard` (`bin/instance-admin` does). Assuming the default `DATABASE_PATH`, run `chown custyard:custyard /data/custyard.db*`, then restart the app (`fly apps restart custyard`) |
| `bin/custyard remote` or `rpc` fails | Erlang distribution is off. Use `/app/bin/instance-admin` or `bin/custyard eval` |

## References

- [Fly.io Phoenix getting started](https://fly.io/docs/elixir/getting-started/)
- [Fly.io configuration reference](https://fly.io/docs/reference/configuration/)
- [Fly.io community forum](https://community.fly.io/)
- [Fly.io port restrictions](https://community.fly.io/t/allow-mailserver-ports/3215)
- [Fly.io secrets management](https://fly.io/docs/apps/secrets/)
- [Fly.io volumes](https://fly.io/docs/volumes/)
