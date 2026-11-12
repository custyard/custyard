# Custyard

Customer onboarding platform with email ingestion via LMTP/IMAP.

## Background

Custyard is a self-hosted, relationship-centric service platform for the **ante-CRM period**: the interval between a prospect's first pricing-page inquiry ("Join the Waitlist", "Contact Us") and a stable, everyday client relationship. It ingests customer communication with zero friction (routed webhooks, LMTP/IMAP, portal filings), resolves every message to an organization/contact/thread automatically, and replaces the staff's queue discipline with a transparent, configurable attention-scoring engine plus neglect detection — while a white-label-capable portal makes the white-glove relationship legible to the customer.

The full framing lives in the design docs:

- [Problem space and product thesis](docs/design/problem-space.md) — the ante-CRM framing, why existing tool categories don't fit, and the document map
- [Prospect thread loop spec](docs/design/spec-thread-loop.md) — the end-to-end MVP loop: intake → attention queue → threaded reply → delivery tracking → portal
- [Software design document](docs/design/sdd.md) and [implementation status](docs/design/sdd-status.md)

## Ownership and access

An installation operator runs Custyard and administers tenants at `/admin`.
Each tenant owns its workspace, staff, customers, branding, support email,
projects and tasks. Staff work at `/app` on the tenant's registered hostname.
A customer is an organization, including an individual identified by email.
Customers receive independently revocable portal links at `/portal/:token`.
Public inquiries start at `/intake/:key` and continue at `/threads/:token`.

Installation administrators and tenant staff have separate accounts, login
pages, cookies and LiveView sessions. Email domains do not grant authority.
The installation bootstrap email comes from `INSTANCE_ADMIN_EMAIL`; tenant
staff emails and admin/agent roles are tenant database records. The same
address can have separate memberships in different tenants.

See [the tenant architecture plan](docs/design/tenant-architecture-cleanup.md)
and [entity relationships](docs/entity-relationships.md) for ownership details.

## Setup

```bash
mix setup
INSTANCE_ADMIN_EMAIL=installer@example.com overmind start -f Procfile.dev
```

Open `/admin/login` on the configured installation host. In development,
login mail appears at `/dev/mailbox`. System login mail is independent of
tenant support email configuration.

Use the installation console to create a tenant on its own subdomain or custom
hostname and provision its first staff administrator. The installation hostname
is reserved for Custyard. Staff can find their workspace from the installation
homepage, then sign in at `/app/login` on that workspace's hostname. Unknown
hosts are rejected.

Configure encrypted tenant provider credentials and support channels at
`/app/settings/email`. The installation's mail credentials never supply tenant
support access. Channels can suggest a customer, project and label for new
threads; those hints cannot override an existing thread or known sender.
See the [support email setup guide](docs/ops/lettermint-email-setup.md).

### Production (Docker / Fly)

A new install needs six variables. The default database is a SQLite file on
the `/data` volume, so there are no database variables. Uploaded logos and
email attachments are stored in the database, not on disk: with a remote
database (Turso, Bunny Database) the container needs no volume. See
[database operations](docs/ops/database.md#files-in-the-database), which also
covers upgrading an install whose files are still on a volume.

```bash
SECRET_KEY_BASE=              # mix phx.gen.secret
CREDENTIAL_ENCRYPTION_KEY=    # openssl rand -base64 32
PHX_HOST=custyard.example.com # the installation hostname
INSTANCE_ADMIN_EMAIL=you@example.com
MAIL_ADAPTER=lettermint       # or smtp | postmark | sendgrid | mailgun
LETTERMINT_PROJECT_TOKEN=     # the credential for the chosen adapter; see .env.sample
```

On Fly, `PHX_HOST` falls back to `FLY_APP_NAME.fly.dev`. `CREDENTIAL_ENCRYPTION_KEY`
encrypts stored tenant credentials; rotate it by moving the old value to
`CREDENTIAL_ENCRYPTION_KEY_PREVIOUS`. `EMAIL_FROM_ADDRESS` defaults to
`noreply@PHX_HOST` and must be a sender the provider has verified; otherwise
the welcome mail and the login links fail the same way.

#### What happens on boot

With variables missing or malformed, the container stays up and serves a doctor
card at every HTML path (HTTP 503). The card names the variables and gives a
paste block; the same report prints to the log. Fix them and restart. With
variables set, the HTTP endpoint comes up first and serves a starting card while
the database is probed and migrations run, so liveness answers throughout. With
no reachable database it then serves a database card and retries
every 10 s; once the database answers it exits with status 1 so the platform's
restart policy (Fly's default `on-failure`, compose `unless-stopped`) runs a
normal boot. A failed migration does not retry. With an empty database it runs
the migrations, creates the installation administrator from
`INSTANCE_ADMIN_EMAIL`, sends a welcome mail through the real adapter, and shows
the setup checklist on `/` for the rest of that boot; sign in at `/admin/login`.
No tenant, staff membership or support connection is created implicitly.
Credential values never appear on a card or in the log, only variable names;
the SQLite path is the one value shown.

Platform health checks must use `/api/health/live`, which is 200 whenever the
process answers. `/api/health` is readiness and returns 503 in doctor modes.
Both answer on any hostname, because platform probes cannot send the
installation or a tenant hostname.

`bin/doctor` prints the same report from a shell (exit 1 unless complete);
`--probe-database` also connects to the configured database and exits 1 if
either has a problem. Before deploying against a remote database, probe a
disposable one from your laptop. Images are published per commit as
`sha-<commit>`; there is no `latest` tag:

```bash
docker run --rm registry.gitlab.com/custyard/custyard:sha-<commit> bin/doctor --probe-database libsql://scratch.turso.io --token "$TURSO_AUTH_TOKEN"
```

After login, `/admin/system` shows the same report plus the last mail
delivery result (installation administrators only).

#### Installation administrators

The account named by `INSTANCE_ADMIN_EMAIL` is created on the first run if
absent and never modified afterwards. Unset it after the first login; the
account remains stored in the installation database.

```bash
fly secrets set INSTANCE_ADMIN_EMAIL=installer@example.com
# After the first successful installation-admin login:
fly secrets unset INSTANCE_ADMIN_EMAIL
```

The database-only release CLI manages installation administrators. It starts
only the database, never the app, so it is safe while the server runs. In a
doctor mode it prints the boot report and exits 1.

```bash
bin/instance-admin add installer@example.com
bin/instance-admin list
bin/instance-admin remove installer@example.com
```

It refuses to remove the last installation administrator. Tenant staff are
managed in the tenant workspace; creating an installation administrator does
not grant tenant membership or access to customer data.

## Validation and database reset

```bash
mix ci
ACKNOWLEDGMENTS_TEST_AMQP_URL=amqp://guest:guest@127.0.0.1:5672 mix test
```

The schema is a fresh baseline. After validating changes, explicitly reset the
intended development database with `mix ecto.reset`. No compatibility migration
or default tenant is created. Resetting invalidates existing login, thread,
portal and claim links. Provision tenants and staff again through `/admin`.

Local Docker run (plain `docker compose up --build` also works and reports the
build as unknown):

```bash
GIT_SHA=$(git rev-parse HEAD) BUILD_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ) docker compose up --build
```

Then open http://localhost:4000. With no environment set it shows the doctor
card; add the six variables to `docker-compose.yml` and run it again.

## Phoenix.new / Remote VM Setup

### GitHub Auth (Device Flow)

```bash
gh auth login
```

Select:
1. `GitHub.com`
2. `HTTPS`
3. `Yes` (authenticate git)
4. `Login with a web browser`

Copy the one-time code, then on your local machine:

https://github.com/login/device

Paste code, authorize. VM session completes automatically.

```bash
gh auth setup-git
```

### Clone Private Repo

```bash
git clone https://github.com/owner/private-repo.git
```

## Docs

- [Set up Custyard on Bunny](docs/ops/bunny-setup.md)

- [Development Guide](docs/development.md)
- [Publishing container images](docs/ops/container-publishing.md)
- [Bunny production and Fly staging plan](docs/ops/bunny-production-fly-staging.md)
- [LMTP Troubleshooting](docs/lmtp-troubleshooting.md)
- [Email Test Strategy](docs/backlog/0323-email-test-strategy.md)
