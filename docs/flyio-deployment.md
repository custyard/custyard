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

# Name the first super_admin; the entrypoint creates it on the next boot.
# Login is magic-link-only, so without an operator nobody can sign in.
fly secrets set OPERATOR_EMAIL=you@example.com

# Deploy
fly deploy

# After your first login, stop recreating that account on every boot
fly secrets unset OPERATOR_EMAIL
```

Instead of `OPERATOR_EMAIL` you can create the account on the running machine
with `fly ssh console -a custyard -C "/app/bin/operator add you@example.com"`.
See [Operator accounts](#operator-accounts).

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
| `min_machines_running` | `1` | Keeps one machine warm for WebSocket (󠄁L󠄁i󠄁v󠄁e󠄁V󠄁i󠄁e󠄁w󠄁)󠄁.󠄁 A󠄁 f󠄁l󠄁o󠄁o󠄁r󠄁,󠄁 n󠄁o󠄁t󠄁 a󠄁 c󠄁a󠄁p󠄁 —󠄁 c󠄁a󠄁p󠄁 t󠄁h󠄁e󠄁 c󠄁o󠄁u󠄁n󠄁t󠄁 w󠄁i󠄁t󠄁h󠄁 `fly scale count 1` |
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
| `UPLOAD_DIR` | `/data/uploads` | Persistent upload directory (must be on the mounted volume) |
| `ATTACHMENT_DIR` | `/data/attachments` | Inbound email attachments, served only through the authenticated operator endpoint (must be on the mounted volume) |

`CREDENTIAL_ENCRYPTION_KEY` is a secret (`fly secrets set CREDENTIAL_ENCRYPTION_KEY="$(openssl rand -base64 32)"`). IMAP channels need it to store their passwords; see [inbound channels](ops/inbound-channels.md#credential-encryption-key). The global `IMAP_*` settings were removed, and a deployment that still sets `IMAP_ENABLED` refuses to start.

## Colonel acknowledgments

Production subscribes to Colonel acknowledgments by default. The consumer
starts once both secrets are set; until then the app boots without it and logs
which variables are missing. Setting only one of them stops the app from
starting, and the machine restarts in a loop until the other is set or the
first is unset with `fly secrets unset`. Each secrets change restarts the app,
so set both in one import as below. The URL carries the broker password, so
keep it off the command line: in bash, `read -rs` takes it without echo or
shell history, and `printf` (a builtin) hands it to `fly secrets import` on
stdin, out of the process list. The URL has the form
`amqps://USER:PASSWORD@BROKER:5671/VHOST?cacertfile=/etc/ssl/certs/ca-certificates.crt&verify=verify_peer`.

```bash
read -rs amqp_url   # paste the URL; nothing is echoed
printf 'ACKNOWLEDGMENTS_AMQP_URL=%s\nACKNOWLEDGMENTS_SOURCE=ots.eu.production\n' "$amqp_url" |
  fly secrets import -a custyard
unset amqp_url

# Explicitly off, for an instance that does not take acknowledgments
fly secrets set ACKNOWLEDGMENTS_ENABLED=false

# Status, queue counts and recovery from the machine
fly ssh console -a custyard -C "/app/bin/acknowledgments status"
```

Provision the broker queues and bind organizations before enabling publication.
See [Operating Colonel acknowledgments](ops/acknowledgments.md) for credentials,
TLS, the operator page at `/operator/acknowledgments`, and the full command set.

## Health check

`GET /api/health` returns `{"status":"ok"}` with a 200 status. Fly.io uses this to verify machine readiness. Configured in `fly.toml` under `[checks.health]`.

## Deployment lifecycle

On every deploy, the container entrypoint (`entrypoint.sh`) runs:

1. Validates `SECRET_KEY_BASE` is set (fails fast if missing)
2. Runs Ecto migrations
3. Bootstraps the operator account: with `OPERATOR_EMAIL` set, creates that
   `super_admin` if it does not exist (an existing account is logged as "exists
   (role X), not modified") and logs a reminder to unset it; an invalid value
   fails the boot. Unset, it logs how to create the first operator. While a
   `super_admin` `admin@custyard.local` exists, it logs a warning. Steps 2 and 3
   run in one `bin/custyard eval` that does not start the app.
4. Starts the Phoenix server

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
`bin/custyard remote` and `bin/custyard rpc` do not work. Use `bin/operator` for
accounts, `bin/dsar` for data subject requests, or `bin/custyard eval` for
one-off code: it runs in a separate VM with the app's configuration and does not
start the app. Anything that writes the database must run as `custyard`
(`bin/operator` and `bin/dsar` switch user themselves).

## Operator accounts

Operators log in with a link emailed to them; there are no passwords. Manage
accounts with `bin/operator`, which starts only the database (never the app), so
it is safe while the server runs:

```bash
# Create a super_admin (the default role)
fly ssh console -a custyard -C "/app/bin/operator add you@example.com"

# Create an admin or agent for one organization (the number in /operator/organizations/ID)
fly ssh console -a custyard -C "/app/bin/operator add lead@example.com --role admin --organization 3"
fly ssh console -a custyard -C "/app/bin/operator add helper@example.com --role agent --organization 3"

# Show id, email, role, organization and creation time, flagging accounts that cannot log in
fly ssh console -a custyard -C "/app/bin/operator list"

# Delete an account (refuses to remove the last super_admin who can log in)
fly ssh console -a custyard -C "/app/bin/operator remove helper@example.com"

fly ssh console -a custyard -C "/app/bin/operator help"
```

- `add` never modifies an existing account: it reports "exists (role X), not
  modified". To change a role, remove the account and add it again.
- Emails are case-insensitive and stored lowercased.
- The "check your email" page is identical for addresses without an account, so
  a mistyped address looks like success. Check `bin/operator list`.
- `OPERATOR_EMAIL` creates a `super_admin` on boot when it does not exist. Unset
  it after the first login: while it is set, a removed operator with that address
  comes back on the next boot.
- Every account created or removed outside the web UI is recorded as an
  `operator_created` or `operator_removed` audit event.
- A login session is tied to the account, not only to its id, so removing an
  operator ends their sessions even if a later account reuses the id. Sessions
  issued before this was introduced are signed out once; log in again.

### Removing the old admin@custyard.local

Older images seeded `admin@custyard.local` as a `super_admin`. No mail reaches
that address, so it can never log in. Boot logs a warning while it exists and
`list` flags it. After your own `super_admin` can log in:

```bash
fly ssh console -a custyard -C "/app/bin/operator remove admin@custyard.local"
```

## Data subject requests

`bin/dsar` exports or erases what one email address appears on in one
organization: as sender, To, CC or Reply-To. Like `bin/operator`, it starts only
the database (never the app), so it is safe while the server runs. `ID` is the
organization's number, the one in `/operator/organizations/ID`.

```bash
# Every message the address appears on, as JSON on stdout; the body only for
# messages the person sent
fly ssh console -a custyard -C "runuser -u custyard -- /app/bin/dsar export pat@example.com --org 3"

# Remove the address from recipient lists and Reply-To on messages the person
# did not send; reports how many messages they sent
fly ssh console -a custyard -C "runuser -u custyard -- /app/bin/dsar erase pat@example.com --org 3 --yes"

# The same, plus the messages the person sent (tombstoned and emptied), their
# attachments, contact record, conversation subjects and rejection-log entries
fly ssh console -a custyard -C "runuser -u custyard -- /app/bin/dsar erase-contact pat@example.com --org 3 --yes"

fly ssh console -a custyard -C "runuser -u custyard -- /app/bin/dsar help"
```

- Erasures are irreversible and refuse to run without `--yes`. An invalid
  address, a missing, repeated or unknown `--org`, or any other usage error
  exits 1 before the database is opened.
- Every erasure writes a `data_subject_erasure` audit event with counts only.
  Neither the audit event nor an error message contains the address.
- Erasure is scoped to one organization: unlinked public-intake conversations
  and prospect records are not covered (spec-inbound-channels, Follow-ups).
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

> **Single-node constraint:** a󠄁 F󠄁l󠄁y󠄁 v󠄁o󠄁l󠄁u󠄁m󠄁e󠄁 a󠄁t󠄁t󠄁a󠄁c󠄁h󠄁e󠄁s󠄁 t󠄁o󠄁 e󠄁x󠄁a󠄁c󠄁t󠄁l󠄁y󠄁 o󠄁n󠄁e󠄁 m󠄁a󠄁c󠄁h󠄁i󠄁n󠄁e󠄁,󠄁 s󠄁o󠄁
> e󠄁v󠄁e󠄁r󠄁y󠄁 e󠄁x󠄁t󠄁r󠄁a󠄁 m󠄁a󠄁c󠄁h󠄁i󠄁n󠄁e󠄁 g󠄁e󠄁t󠄁s󠄁 i󠄁t󠄁s󠄁 o󠄁w󠄁n󠄁 v󠄁o󠄁l󠄁u󠄁m󠄁e󠄁 a󠄁n󠄁d󠄁 i󠄁t󠄁s󠄁 o󠄁w󠄁n󠄁 S󠄁Q󠄁L󠄁i󠄁t󠄁e󠄁 d󠄁a󠄁t󠄁a󠄁b󠄁a󠄁s󠄁e󠄁.󠄁 T󠄁w󠄁o󠄁
> m󠄁a󠄁c󠄁h󠄁i󠄁n󠄁e󠄁s󠄁 m󠄁e󠄁a󠄁n󠄁s󠄁 t󠄁w󠄁o󠄁 d󠄁a󠄁t󠄁a󠄁b󠄁a󠄁s󠄁e󠄁s󠄁 t󠄁h󠄁a󠄁t󠄁 d󠄁i󠄁v󠄁e󠄁r󠄁g󠄁e󠄁 s󠄁i󠄁l󠄁e󠄁n󠄁t󠄁l󠄁y󠄁:󠄁 w󠄁r󠄁i󠄁t󠄁e󠄁s󠄁 l󠄁a󠄁n󠄁d󠄁 o󠄁n󠄁 w󠄁h󠄁i󠄁c󠄁h󠄁e󠄁v󠄁e󠄁r󠄁
> m󠄁a󠄁c󠄁h󠄁i󠄁n󠄁e󠄁 t󠄁h󠄁e󠄁 p󠄁r󠄁o󠄁x󠄁y󠄁 p󠄁i󠄁c󠄁k󠄁e󠄁d󠄁,󠄁 a󠄁n󠄁d󠄁 t󠄁h󠄁e󠄁 a󠄁p󠄁p󠄁 k󠄁e󠄁e󠄁p󠄁s󠄁 r󠄁e󠄁p󠄁o󠄁r󠄁t󠄁i󠄁n󠄁g󠄁 h󠄁e󠄁a󠄁l󠄁t󠄁h󠄁y󠄁.󠄁
>
> `min_machines_running = 1` d󠄁o󠄁e󠄁s󠄁 n󠄁o󠄁t󠄁 p󠄁r󠄁e󠄁v󠄁e󠄁n󠄁t󠄁 t󠄁h󠄁i󠄁s󠄁.󠄁 I󠄁t󠄁 i󠄁s󠄁 a󠄁 f󠄁l󠄁o󠄁o󠄁r󠄁 o󠄁n󠄁 h󠄁o󠄁w󠄁 m󠄁a󠄁n󠄁y󠄁
> m󠄁a󠄁c󠄁h󠄁i󠄁n󠄁e󠄁s󠄁 s󠄁t󠄁a󠄁y󠄁 w󠄁a󠄁r󠄁m󠄁,󠄁 n󠄁o󠄁t󠄁 a󠄁 c󠄁a󠄁p󠄁 o󠄁n󠄁 h󠄁o󠄁w󠄁 m󠄁a󠄁n󠄁y󠄁 e󠄁x󠄁i󠄁s󠄁t󠄁.󠄁 E󠄁n󠄁f󠄁o󠄁r󠄁c󠄁e󠄁 t󠄁h󠄁e󠄁 c󠄁a󠄁p󠄁 e󠄁x󠄁p󠄁l󠄁i󠄁c󠄁i󠄁t󠄁l󠄁y󠄁:󠄁
>
> ```sh
> fly scale count 1 -a custyard   # verify with: fly scale show -a custyard
> ```
>
> C󠄁h󠄁e󠄁c󠄁k󠄁 `fly scale show` b󠄁e󠄁f󠄁o󠄁r󠄁e󠄁 e󠄁v󠄁e󠄁r󠄁y󠄁 d󠄁e󠄁p󠄁l󠄁o󠄁y󠄁 t󠄁h󠄁a󠄁t󠄁 t󠄁o󠄁u󠄁c󠄁h󠄁e󠄁s󠄁 `[mounts]`.󠄁 A󠄁 d󠄁e󠄁p󠄁l󠄁o󠄁y󠄁
> t󠄁h󠄁a󠄁t󠄁 i󠄁n󠄁t󠄁r󠄁o󠄁d󠄁u󠄁c󠄁e󠄁s󠄁 a󠄁 m󠄁o󠄁u󠄁n󠄁t󠄁 w󠄁h󠄁i󠄁l󠄁e󠄁 t󠄁h󠄁e󠄁 a󠄁p󠄁p󠄁 h󠄁a󠄁s󠄁 t󠄁w󠄁o󠄁 m󠄁a󠄁c󠄁h󠄁i󠄁n󠄁e󠄁s󠄁 c󠄁r󠄁e󠄁a󠄁t󠄁e󠄁s󠄁 a󠄁 s󠄁e󠄁c󠄁o󠄁n󠄁d󠄁
> v󠄁o󠄁l󠄁u󠄁m󠄁e󠄁 a󠄁n󠄁d󠄁 s󠄁p󠄁l󠄁i󠄁t󠄁s󠄁 t󠄁h󠄁e󠄁 d󠄁a󠄁t󠄁a󠄁b󠄁a󠄁s󠄁e󠄁.󠄁 T󠄁h󠄁e󠄁 a󠄁p󠄁p󠄁 r󠄁e󠄁f󠄁u󠄁s󠄁e󠄁s󠄁 t󠄁o󠄁 b󠄁o󠄁o󠄁t󠄁 w󠄁h󠄁e󠄁n󠄁 m󠄁o󠄁r󠄁e󠄁 t󠄁h󠄁a󠄁n󠄁 o󠄁n󠄁e󠄁
> m󠄁a󠄁c󠄁h󠄁i󠄁n󠄁e󠄁 r󠄁u󠄁n󠄁s󠄁 a󠄁g󠄁a󠄁i󠄁n󠄁s󠄁t󠄁 a󠄁 l󠄁o󠄁c󠄁a󠄁l󠄁 S󠄁Q󠄁L󠄁i󠄁t󠄁e󠄁 f󠄁i󠄁l󠄁e󠄁 (󠄁`Custyard.Storage`)󠄁,󠄁 b󠄁u󠄁t󠄁 t󠄁h󠄁e󠄁 r󠄁e󠄁f󠄁u󠄁s󠄁a󠄁l󠄁
> i󠄁s󠄁 a󠄁 b󠄁a󠄁c󠄁k󠄁s󠄁t󠄁o󠄁p󠄁,󠄁 n󠄁o󠄁t󠄁 a󠄁 s󠄁u󠄁b󠄁s󠄁t󠄁i󠄁t󠄁u󠄁t󠄁e󠄁 f󠄁o󠄁r󠄁 t󠄁h󠄁e󠄁 s󠄁c󠄁a󠄁l󠄁e󠄁 c󠄁h󠄁e󠄁c󠄁k󠄁.󠄁
>
> F󠄁o󠄁r󠄁 m󠄁u󠄁l󠄁t󠄁i󠄁-󠄁r󠄁e󠄁g󠄁i󠄁o󠄁n󠄁 o󠄁r󠄁 m󠄁u󠄁l󠄁t󠄁i󠄁-󠄁m󠄁a󠄁c󠄁h󠄁i󠄁n󠄁e󠄁 s󠄁e󠄁t󠄁u󠄁p󠄁s󠄁,󠄁 m󠄁i󠄁g󠄁r󠄁a󠄁t󠄁e󠄁 t󠄁o󠄁 P󠄁o󠄁s󠄁t󠄁g󠄁r󠄁e󠄁S󠄁Q󠄁L󠄁.󠄁 S󠄁e󠄁e󠄁
> [Fly Postgres docs](https://fly.io/docs/postgres/).

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
| Migration failures | Run manually as the app user: `fly ssh console -a custyard -C "runuser -u custyard -- /app/bin/custyard eval 'Custyard.Release.migrate()'"` |
| Nobody can log in | `fly ssh console -a custyard -C "/app/bin/operator list"`; create an account with `/app/bin/operator add you@example.com` or `fly secrets set OPERATOR_EMAIL=you@example.com` and redeploy |
| Login link never arrives | The "check your email" page is shown even for unknown addresses. Confirm the account with `/app/bin/operator list`, then check `MAIL_ADAPTER` and `fly logs` |
| Boot fails with `OPERATOR_EMAIL: ...` | The value is not a valid address (or is `admin@custyard.local`). Fix or unset it: `fly secrets unset OPERATOR_EMAIL` |
| "No organization assigned; ask a super admin" | The operator's organization was deleted. Remove the account with `/app/bin/operator remove EMAIL` and add it again with `--role` and `--organization` |
| Database becomes read-only after an SSH session | Something wrote the database as root. Run app commands as `custyard` (`bin/operator` does). Assuming the default `DATABASE_PATH`, run `chown custyard:custyard /data/custyard.db*`, then restart the app (`fly apps restart custyard`) |
| `bin/custyard remote` or `rpc` fails | Erlang distribution is off. Use `/app/bin/operator` or `bin/custyard eval` |

## References

- [Fly.io Phoenix getting started](https://fly.io/docs/elixir/getting-started/)
- [Fly.io configuration reference](https://fly.io/docs/reference/configuration/)
- [Fly.io community forum](https://community.fly.io/)
- [Fly.io port restrictions](https://community.fly.io/t/allow-mailserver-ports/3215)
- [Fly.io secrets management](https://fly.io/docs/apps/secrets/)
- [Fly.io volumes](https://fly.io/docs/volumes/)
