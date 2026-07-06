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
- [Email Test Strategy](docs/qa/email-test-strategy.md)
