# README.md
---

# Custyard

Customer onboarding platform with email ingestion via LMTP/IMAP.

## Background

### What Custyard is

A Phoenix/LiveView app with three surfaces (visible in the 0322 route table):

- Intake API — /api/webhook/inbound and per-org routed webhooks (/webhook/route/:callback_token) that receive inbound email via Lettermint, verify HMAC signatures, resolve the sender to a contact/thread, and create or continue conversations. This is where pricing-page CTAs would land: a waitlist signup or quote request becomes a conversation in a queue.
- Operator side (/operator/...) — an attention queue of conversations, per-conversation view with replies, organizations management, and settings. Operators are your team doing the white-glove work. There's an RBAC schema (admin/agent/viewer) and a scoring/attention mechanism.
- Customer portal (/p/:org_token/...) — a token-gated space where a prospect/customer sees their requests, opens new ones, and follows the thread. This is the customer-facing half of the "waiting room."

The core object is the conversation: state machine (waiting/active/resolved/dormant), messages with email threading metadata (Message-ID, In-Reply-To, References), immutable message log, audit events, PubSub-driven live updates to both operator and portal views.

### The problem space

Onetime Secret (and products like it) sells high-touch tiers — dedicated instances, custom domains, forked codebases (the "global elite" customer in the 0307 email is the archetype). The buying journey for those tiers doesn't fit either of the two tools that normally exist:

1. Before the sale, the pricing page ends in soft CTAs — "Join the Waitlist," "Contact Us for a quote." Today those CTAs presumably dump into a shared inbox. There's no structured intake, no queue, no state.
2. After the sale but before steady state, onboarding is a long, stateful, multi-message correspondence: provision the instance, walk through CNAME/TLS setup, iterate on customizations ("restrict the homepage," "change expiration defaults"), check in next week. The 0307 file is literally you hand-drafting and redrafting that email — that's the workflow being productized.

This is the ante-CRM period: too early and too messy for a CRM (no stable account, lots of back-and-forth, high uncertainty about whether they'll convert), but too important for a plain support inbox (these are the highest-value prospects, and the white-glove experience is the product differentiator). Your CloudFlare-waiting-room analogy fits: it's a managed front door that absorbs interest from a page and turns it into an orderly, operator-driven onboarding pipeline — except human-paced and relationship-shaped rather than traffic-shaping.

### Where it actually stands (per the March notes)

The MVP-critical loop is inbound works, outbound is the gap. Chronologically:

- 0324 quality quest: a full audit logged 156 findings — the P1 themes were unauthenticated webhooks, atom-table exhaustion from String.to_existing_atom on user input, portal auth defined-but-not-wired, session fixation, and anonymous portal requests. Early-stage hardening debt, catalogued into a task DB and worked down.
- 0326/0327 foundational layer: the dependency graph for email. Phase 1: #27 route management + #12 team-role enforcement (RBAC is schema-only — any operator can do anything, and building route-management UI before enforcement creates an unguarded admin surface). Phase 2: #26 outbound email — as of 0327, send_reply persisted a message and sent nothing; the Lettermint client had no send_message. Phase 3: #25 status webhooks, blocked on #26. Also flagged: dual inbound processors (legacy Email.Processor vs routed SenderMatching) that need consolidating before reply logic gets written twice.
- 0329 notes: #26 was substantially implemented (Swoosh + Lettermint adapter, delivery_status, threading headers) with known follow-ups — the orphaned ThreadHeaders module needs wiring into Outbound.compose/4, no verified-sender validation, and the state-machine bypass in send_reply. #25 remains blocked on one concrete gap: deliver/1 discards the Swoosh metadata containing lettermint_message_id, so status callbacks have no correlation key.

The MVP bar, restated

For the pricing-page connection to work end-to-end, a prospect must be able to: click "Join the Waitlist"/"Contact Us" → land as an identified conversation in an org's queue (needs routed webhooks per org — #27 — and non-anonymous intake, a P1 from the audit) → an operator replies from the queue and the reply actually arrives as a properly threaded email (#26) → delivery is trackable so silent failures don't burn a high-value prospect (#25) → the prospect can follow along in the portal. Everything in the notes converges on that single loop; the sequencing discipline (roles before admin UI, message-ID capture before status webhooks, processor consolidation before reply logic) is about not building the loop twice or leaving it unguarded.

One observation: the 0307 email drafts are worth keeping close — they're the ground truth for what the content of these conversations looks like (provisioning links, DNS instructions, customization menus, "I'll check in next week"). Templates/snippets for exactly that correspondence are an obvious near-term feature once the send loop closes.


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
