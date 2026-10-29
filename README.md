# Custyard

Customer onboarding platform with email ingestion via LMTP/IMAP.

## Background

Custyard is a self-hosted, relationship-centric service platform for the **ante-CRM period**: the interval between a prospect's first pricing-page inquiry ("Join the Waitlist", "Contact Us") and a stable, everyday client relationship. It ingests customer communication with zero friction (routed webhooks, LMTP/IMAP, portal filings), resolves every message to an organization/contact/conversation automatically, and replaces the operator's queue discipline with a transparent, configurable attention-scoring engine plus neglect detection — while a white-label-capable portal makes the white-glove relationship legible to the customer.

The full framing lives in the design docs:

- [Problem space and product thesis](docs/design/problem-space.md) — the ante-CRM framing, why existing tool categories don't fit, and the document map
- [Prospect conversation loop spec](docs/design/spec-conversation-loop.md) — the end-to-end MVP loop: intake → attention queue → threaded reply → delivery tracking → portal
- [Software design document](docs/design/sdd.md) and [implementation status](docs/design/sdd-status.md)

## Onboarding to Custyard

Connect the dots from our pricing page for items with CTAs like Join the Waitlist and Contact Us (for a quote) to a new project in Custyard, kind of like CloudFlare's waiting room feature for managing high traffic to a particular page or site, except it's like the first step in a white glove service for onboarding potential and actual customers, during the ante-CRM period when there's a lot going on and it's not a stable everyday operations client relationship yet.

Redirect 5-10 a multiplicity of "asks" from potential customers from "enterprise plan" (which means different thing to different people), global elite, custom installs, etc from my email inbox to a single place where I can triage and respond to them in a white-glove way, and where they can see the status of their request and follow the conversation.


- Intake API — /api/webhook/inbound and per-org routed webhooks (/webhook/route/:callback_token) that receive inbound email via Lettermint, verify HMAC signatures, resolve the sender to a contact/thread, and create or continue conversations. This is where pricing-page CTAs would land: a waitlist signup or quote request becomes a conversation in a queue.
- Operator side (/operator/...) — an attention queue of conversations, per-conversation view with replies, organizations management, and settings. Operators are your team doing the white-glove work. There's an RBAC schema (admin/agent/viewer) and a scoring/attention mechanism.
- Customer portal (/p/:org_token/...) — a token-gated space where a prospect/customer sees their requests, opens new ones, and follows the thread. This is the customer-facing half of the "waiting room."

The core object is the conversation: state machine (waiting/active/resolved/dormant), messages with email threading metadata (Message-ID, In-Reply-To, References), immutable message log, audit events, PubSub-driven live updates to both operator and portal views.


## Setup

```bash
mix setup
overmind start -f Procfile.dev
```

mix compile && mix fly.secrets 


http://localhost:4000

## Admin login (fresh instance)

Custyard uses **email-only auth**: operators log in with a magic link, no password.
Roles are `super_admin` (all orgs), `admin` (one org), and `agent` (support); the
default for a new account is `super_admin`.

### Local dev

A `super_admin` account is created for you automatically. On every boot,
`Custyard.Application` inserts `admin@custyard.local` if it doesn't already exist —
so a fresh checkout after `mix setup` already has an admin. To log in:

1. Open http://localhost:4000/operator/login and enter `admin@custyard.local`.
2. The magic link is captured by the Swoosh local (in-memory) mailer. Open the
   dev mailbox at http://localhost:4000/dev/mailbox and click the login link.
   (Link expires in 15 minutes; request a new one if it lapses.)

To use a different email instead of the default:

```bash
mix dev.create_operator --email you@example.com
```

### Production (Docker / Fly)

Login links need a real mailer, so set `MAIL_ADAPTER` (`lettermint` | `postmark` |
`sendgrid` | `mailgun` | `smtp`) and its credentials (see `.env.sample`). Then create
the first `super_admin` in one of two ways.

F󠄁o󠄁r󠄁 L󠄁e󠄁t󠄁t󠄁e󠄁r󠄁m󠄁i󠄁n󠄁t󠄁,󠄁 `LETTERMINT_PROJECT_TOKEN` s󠄁e󠄁n󠄁d󠄁s󠄁 i󠄁n󠄁s󠄁t󠄁a󠄁l󠄁l󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 m󠄁a󠄁i󠄁l󠄁 (󠄁i󠄁n󠄁c󠄁l󠄁u󠄁d󠄁i󠄁n󠄁g󠄁
l󠄁o󠄁g󠄁i󠄁n󠄁 l󠄁i󠄁n󠄁k󠄁s󠄁)󠄁,󠄁 w󠄁h󠄁i󠄁l󠄁e󠄁 t󠄁h󠄁e󠄁 s󠄁e󠄁p󠄁a󠄁r󠄁a󠄁t󠄁e󠄁 `LETTERMINT_TEAM_TOKEN` a󠄁u󠄁t󠄁h󠄁o󠄁r󠄁i󠄁z󠄁e󠄁s󠄁 m󠄁a󠄁n󠄁a󠄁g󠄁e󠄁m󠄁e󠄁n󠄁t󠄁
r󠄁e󠄁a󠄁d󠄁s󠄁.󠄁 `LETTERMINT_API_KEY` r󠄁e󠄁m󠄁a󠄁i󠄁n󠄁s󠄁 a󠄁 d󠄁e󠄁p󠄁r󠄁e󠄁c󠄁a󠄁t󠄁e󠄁d󠄁 s󠄁e󠄁n󠄁d󠄁i󠄁n󠄁g󠄁-󠄁o󠄁n󠄁l󠄁y󠄁 f󠄁a󠄁l󠄁l󠄁b󠄁a󠄁c󠄁k󠄁.󠄁 A󠄁 m󠄁i󠄁s󠄁s󠄁i󠄁n󠄁g󠄁
T󠄁e󠄁a󠄁m󠄁 t󠄁o󠄁k󠄁e󠄁n󠄁 d󠄁i󠄁s󠄁a󠄁b󠄁l󠄁e󠄁s󠄁 p󠄁r󠄁o󠄁d󠄁u󠄁c󠄁t󠄁i󠄁o󠄁n󠄁 m󠄁a󠄁n󠄁a󠄁g󠄁e󠄁m󠄁e󠄁n󠄁t󠄁;󠄁 i󠄁t󠄁 n󠄁e󠄁v󠄁e󠄁r󠄁 c󠄁r󠄁e󠄁a󠄁t󠄁e󠄁s󠄁 m󠄁o󠄁c󠄁k󠄁 r󠄁o󠄁u󠄁t󠄁e󠄁s󠄁.󠄁

A󠄁f󠄁t󠄁e󠄁r󠄁 l󠄁o󠄁g󠄁i󠄁n󠄁,󠄁 c󠄁h󠄁o󠄁o󠄁s󠄁e󠄁 t󠄁h󠄁e󠄁 t󠄁e󠄁n󠄁a󠄁n󠄁t󠄁 a󠄁n󠄁d󠄁 o󠄁p󠄁e󠄁n󠄁 **E󠄁m󠄁a󠄁i󠄁l󠄁 s󠄁e󠄁t󠄁u󠄁p󠄁** a󠄁t󠄁
`/operator/email-setup`.󠄁 T󠄁h󠄁e󠄁 m󠄁i󠄁g󠄁r󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 p󠄁l󠄁a󠄁c󠄁e󠄁s󠄁 e󠄁x󠄁i󠄁s󠄁t󠄁i󠄁n󠄁g󠄁 c󠄁u󠄁s󠄁t󠄁o󠄁m󠄁e󠄁r󠄁 o󠄁r󠄁g󠄁a󠄁n󠄁i󠄁z󠄁a󠄁t󠄁i󠄁o󠄁n󠄁s󠄁,󠄁
c󠄁o󠄁n󠄁v󠄁e󠄁r󠄁s󠄁a󠄁t󠄁i󠄁o󠄁n󠄁s󠄁 a󠄁n󠄁d󠄁 c󠄁h󠄁a󠄁n󠄁n󠄁e󠄁l󠄁s󠄁 i󠄁n󠄁 t󠄁h󠄁e󠄁 **D󠄁e󠄁f󠄁a󠄁u󠄁l󠄁t󠄁** t󠄁e󠄁n󠄁a󠄁n󠄁t󠄁.󠄁 G󠄁l󠄁o󠄁b󠄁a󠄁l󠄁 e󠄁n󠄁v󠄁i󠄁r󠄁o󠄁n󠄁m󠄁e󠄁n󠄁t󠄁 t󠄁o󠄁k󠄁e󠄁n󠄁s󠄁
o󠄁n󠄁l󠄁y󠄁 b󠄁o󠄁o󠄁t󠄁s󠄁t󠄁r󠄁a󠄁p󠄁 t󠄁h󠄁a󠄁t󠄁 t󠄁e󠄁n󠄁a󠄁n󠄁t󠄁.󠄁 E󠄁a󠄁c󠄁h󠄁 a󠄁d󠄁d󠄁i󠄁t󠄁i󠄁o󠄁n󠄁a󠄁l󠄁 t󠄁e󠄁n󠄁a󠄁n󠄁t󠄁 s󠄁a󠄁v󠄁e󠄁s󠄁 i󠄁t󠄁s󠄁 o󠄁w󠄁n󠄁 e󠄁n󠄁c󠄁r󠄁y󠄁p󠄁t󠄁e󠄁d󠄁
p󠄁r󠄁o󠄁j󠄁e󠄁c󠄁t󠄁 t󠄁o󠄁k󠄁e󠄁n󠄁,󠄁 T󠄁e󠄁a󠄁m󠄁 t󠄁o󠄁k󠄁e󠄁n󠄁,󠄁 s󠄁e󠄁l󠄁e󠄁c󠄁t󠄁e󠄁d󠄁 p󠄁r󠄁o󠄁j󠄁e󠄁c󠄁t󠄁 a󠄁n󠄁d󠄁 w󠄁e󠄁b󠄁h󠄁o󠄁o󠄁k󠄁 s󠄁e󠄁c󠄁r󠄁e󠄁t󠄁s󠄁;󠄁 s󠄁e󠄁t󠄁
`CREDENTIAL_ENCRYPTION_KEY` b󠄁e󠄁f󠄁o󠄁r󠄁e󠄁 d󠄁o󠄁i󠄁n󠄁g󠄁 s󠄁o󠄁.󠄁 S󠄁e󠄁e󠄁 t󠄁h󠄁e󠄁 [s󠄁u󠄁p󠄁p󠄁o󠄁r󠄁t󠄁 e󠄁m󠄁a󠄁i󠄁l󠄁 s󠄁e󠄁t󠄁u󠄁p󠄁
g󠄁u󠄁i󠄁d󠄁e󠄁](docs/ops/lettermint-email-setup.md) f󠄁o󠄁r󠄁 m󠄁a󠄁n󠄁u󠄁a󠄁l󠄁 L󠄁e󠄁t󠄁t󠄁e󠄁r󠄁m󠄁i󠄁n󠄁t󠄁 s󠄁t󠄁e󠄁p󠄁s󠄁 a󠄁n󠄁d󠄁 t󠄁h󠄁e󠄁
r󠄁e󠄁c󠄁e󠄁i󠄁v󠄁e󠄁/󠄁r󠄁e󠄁p󠄁l󠄁y󠄁 v󠄁e󠄁r󠄁i󠄁f󠄁i󠄁c󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 c󠄁h󠄁e󠄁c󠄁k󠄁l󠄁i󠄁s󠄁t󠄁.󠄁

On the next boot: set `OPERATOR_EMAIL` and the entrypoint creates that account if
it does not exist. An existing account is never modified.

```bash
fly secrets set OPERATOR_EMAIL=you@example.com
```

Log in at `/operator/login`, then `fly secrets unset OPERATOR_EMAIL`. While it is
set, every boot logs a reminder, and an operator you remove with that address is
recreated on the next boot.

From a shell on the running machine: `bin/operator` starts only the database,
never the app, so it is safe while the server runs. Under `fly ssh console` it
switches to the `custyard` user itself.

```bash
fly ssh console -a custyard -C "/app/bin/operator add you@example.com"
fly ssh console -a custyard -C "/app/bin/operator add lead@example.com --role admin --organization 3"
fly ssh console -a custyard -C "/app/bin/operator add helper@example.com --role agent --organization 3"
fly ssh console -a custyard -C "/app/bin/operator list"
fly ssh console -a custyard -C "/app/bin/operator remove helper@example.com"
fly ssh console -a custyard -C "/app/bin/operator help"
```

With Docker, run `docker exec <container> bin/operator ...` instead.

- The default role is `super_admin`. `admin` and `agent` need `--organization ID`
  (the number in `/operator/organizations/ID`). `add` reports an existing account
  as "exists (role X), not modified" and never changes its role.
- Emails are case-insensitive: `Ops@Example.com` and `ops@example.com` are the
  same account, stored lowercased.
- The "check your email" page looks the same whether or not the address has an
  account, so a typo looks like success. Check `bin/operator list`.
- `remove` refuses to remove the last `super_admin` who can log in.
- An `admin` or `agent` whose organization was deleted cannot log in ("No
  organization assigned; ask a super admin"); `list` flags them. Remove the
  account and add it again with `--organization`.

Older images seeded `admin@custyard.local` as a `super_admin`. Nothing delivers
mail to that address, so it can never log in; each boot logs a warning while it
exists and `list` flags it. Once your own `super_admin` can log in, remove it:

```bash
fly ssh console -a custyard -C "/app/bin/operator remove admin@custyard.local"
```

Erlang distribution is off in the release, so `bin/custyard remote` and
`bin/custyard rpc` do not work. Use `bin/operator`, or `bin/custyard eval` for
one-off code (a separate VM with the app's configuration; the app is not started).

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
- [P󠄁u󠄁b󠄁l󠄁i󠄁s󠄁h󠄁i󠄁n󠄁g󠄁 c󠄁o󠄁n󠄁t󠄁a󠄁i󠄁n󠄁e󠄁r󠄁 i󠄁m󠄁a󠄁g󠄁e󠄁s󠄁 t󠄁o󠄁 G󠄁H󠄁C󠄁R󠄁](docs/ops/ghcr-publishing.md)
- [B󠄁u󠄁n󠄁n󠄁y󠄁 p󠄁r󠄁o󠄁d󠄁u󠄁c󠄁t󠄁i󠄁o󠄁n󠄁 a󠄁n󠄁d󠄁 F󠄁l󠄁y󠄁 s󠄁t󠄁a󠄁g󠄁i󠄁n󠄁g󠄁 p󠄁l󠄁a󠄁n󠄁](docs/ops/bunny-production-fly-staging.md)
- [LMTP Troubleshooting](docs/lmtp-troubleshooting.md)
- [Email Test Strategy](docs/backlog/0323-email-test-strategy.md)
