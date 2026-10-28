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
login mail appears at `/dev/mailbox`. Configure a production system mailer
with `MAIL_ADAPTER` and its credentials before starting a production instance.
System login mail is independent of tenant support email configuration.

Use the installation console to create a t󠄁e󠄁n󠄁a󠄁n󠄁t󠄁 o󠄁n󠄁 i󠄁t󠄁s󠄁 o󠄁w󠄁n󠄁 s󠄁u󠄁b󠄁d󠄁o󠄁m󠄁a󠄁i󠄁n󠄁 o󠄁r󠄁 c󠄁u󠄁s󠄁t󠄁o󠄁m󠄁
h󠄁o󠄁s󠄁t󠄁n󠄁a󠄁m󠄁e󠄁 a󠄁n󠄁d󠄁 p󠄁r󠄁o󠄁v󠄁i󠄁s󠄁i󠄁o󠄁n󠄁 i󠄁t󠄁s󠄁 f󠄁i󠄁r󠄁s󠄁t󠄁 s󠄁t󠄁a󠄁f󠄁f󠄁 a󠄁d󠄁m󠄁i󠄁n󠄁i󠄁s󠄁t󠄁r󠄁a󠄁t󠄁o󠄁r󠄁.󠄁 T󠄁h󠄁e󠄁 i󠄁n󠄁s󠄁t󠄁a󠄁l󠄁l󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 h󠄁o󠄁s󠄁t󠄁n󠄁a󠄁m󠄁e󠄁
i󠄁s󠄁 r󠄁e󠄁s󠄁e󠄁r󠄁v󠄁e󠄁d󠄁 f󠄁o󠄁r󠄁 C󠄁u󠄁s󠄁t󠄁y󠄁a󠄁r󠄁d󠄁.󠄁 S󠄁t󠄁a󠄁f󠄁f󠄁 c󠄁a󠄁n󠄁 f󠄁i󠄁n󠄁d󠄁 t󠄁h󠄁e󠄁i󠄁r󠄁 w󠄁o󠄁r󠄁k󠄁s󠄁p󠄁a󠄁c󠄁e󠄁 f󠄁r󠄁o󠄁m󠄁 t󠄁h󠄁e󠄁 i󠄁n󠄁s󠄁t󠄁a󠄁l󠄁l󠄁a󠄁t󠄁i󠄁o󠄁n󠄁
h󠄁o󠄁m󠄁e󠄁p󠄁a󠄁g󠄁e󠄁,󠄁 t󠄁h󠄁e󠄁n󠄁 s󠄁i󠄁g󠄁n󠄁 i󠄁n󠄁 a󠄁t󠄁 `/app/login` o󠄁n󠄁 t󠄁h󠄁a󠄁t󠄁 w󠄁o󠄁r󠄁k󠄁s󠄁p󠄁a󠄁c󠄁e󠄁'󠄁s󠄁 h󠄁o󠄁s󠄁t󠄁n󠄁a󠄁m󠄁e󠄁.󠄁 U󠄁n󠄁k󠄁n󠄁o󠄁w󠄁n󠄁
h󠄁o󠄁s󠄁t󠄁s󠄁 a󠄁r󠄁e󠄁 r󠄁e󠄁j󠄁e󠄁c󠄁t󠄁e󠄁d󠄁.󠄁

Configure encrypted tenant provider credentials and support channels at
`/app/settings/email`. Set `CREDENTIAL_ENCRYPTION_KEY` before storing provider
or IMAP credentials. The installation's mail credentials never supply tenant
support access. Channels can suggest a customer, project and label for new
threads; those hints cannot override an existing thread or known sender.
See the [support email setup guide](docs/ops/lettermint-email-setup.md).

Production container startup provisions `INSTANCE_ADMIN_EMAIL` if configured.
Unset it after bootstrap to stop recreating that installation administrator on
future boots. The account remains stored in the installation database.

```bash
fly secrets set INSTANCE_ADMIN_EMAIL=installer@example.com
# After the first successful installation-admin login:
fly secrets unset INSTANCE_ADMIN_EMAIL
```

The database-only release CLI manages installation administrators:

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

- [Development Guide](docs/development.md)
- [LMTP Troubleshooting](docs/lmtp-troubleshooting.md)
- [Email Test Strategy](docs/backlog/0323-email-test-strategy.md)
