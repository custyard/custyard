# Design Decisions: Data Model + Lettermint Integration

**Version:** 0.3
**Date:** 2026-03-24
**Context:** Supplements SDD v0.3. Captures decisions made during design review of Tasks 80, 77, 106 in light of Lettermint's per-project routes and multiple webhooks per route.

---

## Current routing model

T󠄁h󠄁e󠄁 r󠄁o󠄁u󠄁t󠄁e󠄁 o󠄁w󠄁n󠄁e󠄁r󠄁s󠄁h󠄁i󠄁p󠄁 a󠄁n󠄁d󠄁 p󠄁r󠄁o󠄁j󠄁e󠄁c󠄁t󠄁-󠄁r󠄁o󠄁u󠄁t󠄁i󠄁n󠄁g󠄁 d󠄁e󠄁c󠄁i󠄁s󠄁i󠄁o󠄁n󠄁s󠄁 b󠄁e󠄁l󠄁o󠄁w󠄁 a󠄁r󠄁e󠄁 s󠄁u󠄁p󠄁e󠄁r󠄁s󠄁e󠄁d󠄁e󠄁d󠄁 b󠄁y󠄁
[I󠄁n󠄁b󠄁o󠄁u󠄁n󠄁d󠄁 M󠄁a󠄁i󠄁l󠄁 C󠄁h󠄁a󠄁n󠄁n󠄁e󠄁l󠄁s󠄁,󠄁 D󠄁1󠄁](spec-inbound-channels.md#d1-channel-is-a-first-class-operator-visible-object-under-a-route).󠄁
R󠄁e󠄁c󠄁e󠄁i󠄁v󠄁i󠄁n󠄁g󠄁 r󠄁o󠄁u󠄁t󠄁e󠄁s󠄁 b󠄁e󠄁l󠄁o󠄁n󠄁g󠄁 t󠄁o󠄁 t󠄁e󠄁n󠄁a󠄁n󠄁t󠄁s󠄁 a󠄁n󠄁d󠄁 c󠄁a󠄁n󠄁 c󠄁a󠄁r󠄁r󠄁y󠄁 m󠄁u󠄁l󠄁t󠄁i󠄁p󠄁l󠄁e󠄁 e󠄁m󠄁a󠄁i󠄁l󠄁 a󠄁d󠄁d󠄁r󠄁e󠄁s󠄁s󠄁e󠄁s󠄁.󠄁
C󠄁u󠄁s󠄁t󠄁o󠄁m󠄁e󠄁r󠄁,󠄁 C󠄁u󠄁s󠄁t󠄁y󠄁a󠄁r󠄁d󠄁 p󠄁r󠄁o󠄁j󠄁e󠄁c󠄁t󠄁 a󠄁n󠄁d󠄁 l󠄁a󠄁b󠄁e󠄁l󠄁 d󠄁e󠄁f󠄁a󠄁u󠄁l󠄁t󠄁s󠄁 b󠄁e󠄁l󠄁o󠄁n󠄁g󠄁 t󠄁o󠄁 e󠄁a󠄁c󠄁h󠄁 a󠄁d󠄁d󠄁r󠄁e󠄁s󠄁s󠄁'󠄁s󠄁 c󠄁h󠄁a󠄁n󠄁n󠄁e󠄁l󠄁;󠄁
t󠄁h󠄁e󠄁r󠄁e󠄁 a󠄁r󠄁e󠄁 n󠄁o󠄁 c󠄁u󠄁s󠄁t󠄁o󠄁m󠄁e󠄁r󠄁-󠄁o󠄁w󠄁n󠄁e󠄁d󠄁 o󠄁r󠄁 C󠄁u󠄁s󠄁t󠄁y󠄁a󠄁r󠄁d󠄁-󠄁p󠄁r󠄁o󠄁j󠄁e󠄁c󠄁t󠄁-󠄁o󠄁w󠄁n󠄁e󠄁d󠄁 r󠄁o󠄁u󠄁t󠄁e󠄁s󠄁.󠄁 S󠄁e󠄁p󠄁a󠄁r󠄁a󠄁t󠄁e󠄁 r󠄁o󠄁u󠄁t󠄁e󠄁s󠄁
s󠄁e󠄁r󠄁v󠄁e󠄁 s󠄁e󠄁p󠄁a󠄁r󠄁a󠄁t󠄁e󠄁 r󠄁e󠄁c󠄁e󠄁i󠄁v󠄁i󠄁n󠄁g󠄁 c󠄁o󠄁n󠄁f󠄁i󠄁g󠄁u󠄁r󠄁a󠄁t󠄁i󠄁o󠄁n󠄁s󠄁 o󠄁r󠄁 d󠄁i󠄁r󠄁e󠄁c󠄁t󠄁-󠄁M󠄁X󠄁 d󠄁o󠄁m󠄁a󠄁i󠄁n󠄁s󠄁,󠄁 r󠄁a󠄁t󠄁h󠄁e󠄁r󠄁 t󠄁h󠄁a󠄁n󠄁 o󠄁n󠄁e󠄁
r󠄁o󠄁u󠄁t󠄁e󠄁 p󠄁e󠄁r󠄁 C󠄁u󠄁s󠄁t󠄁y󠄁a󠄁r󠄁d󠄁 p󠄁r󠄁o󠄁j󠄁e󠄁c󠄁t󠄁.󠄁 A󠄁 L󠄁e󠄁t󠄁t󠄁e󠄁r󠄁m󠄁i󠄁n󠄁t󠄁 p󠄁r󠄁o󠄁j󠄁e󠄁c󠄁t󠄁 i󠄁s󠄁 t󠄁h󠄁e󠄁 p󠄁r󠄁o󠄁v󠄁i󠄁d󠄁e󠄁r󠄁 c󠄁o󠄁n󠄁f󠄁i󠄁g󠄁u󠄁r󠄁a󠄁t󠄁i󠄁o󠄁n󠄁
s󠄁e󠄁l󠄁e󠄁c󠄁t󠄁e󠄁d󠄁 f󠄁o󠄁r󠄁 t󠄁h󠄁e󠄁 t󠄁e󠄁n󠄁a󠄁n󠄁t󠄁,󠄁 s󠄁e󠄁p󠄁a󠄁r󠄁a󠄁t󠄁e󠄁 f󠄁r󠄁o󠄁m󠄁 C󠄁u󠄁s󠄁t󠄁y󠄁a󠄁r󠄁d󠄁 c󠄁u󠄁s󠄁t󠄁o󠄁m󠄁e󠄁r󠄁 p󠄁r󠄁o󠄁j󠄁e󠄁c󠄁t󠄁s󠄁.󠄁

U󠄁s󠄁e󠄁 [T󠄁e󠄁n󠄁a󠄁n󠄁t󠄁 s󠄁u󠄁p󠄁p󠄁o󠄁r󠄁t󠄁 e󠄁m󠄁a󠄁i󠄁l󠄁 s󠄁e󠄁t󠄁u󠄁p󠄁](../ops/lettermint-email-setup.md) f󠄁o󠄁r󠄁 c󠄁u󠄁r󠄁r󠄁e󠄁n󠄁t󠄁
c󠄁o󠄁n󠄁f󠄁i󠄁g󠄁u󠄁r󠄁a󠄁t󠄁i󠄁o󠄁n󠄁 i󠄁n󠄁s󠄁t󠄁r󠄁u󠄁c󠄁t󠄁i󠄁o󠄁n󠄁s󠄁.󠄁 T󠄁h󠄁e󠄁 r󠄁e󠄁m󠄁a󠄁i󠄁n󠄁i󠄁n󠄁g󠄁 s󠄁e󠄁c󠄁t󠄁i󠄁o󠄁n󠄁s󠄁 r󠄁e󠄁c󠄁o󠄁r󠄁d󠄁 t󠄁h󠄁e󠄁 o󠄁r󠄁i󠄁g󠄁i󠄁n󠄁a󠄁l󠄁 d󠄁e󠄁s󠄁i󠄁g󠄁n󠄁.󠄁

## Lettermint Capabilities Informing These Decisions

- **Per-project inbound and outbound routes**: Every project gets its own unique callback URL. Routing context is embedded in the channel, not reconstructed from sender identity.
- **Multiple webhooks per route**: A single inbound message can fan out to multiple consumers simultaneously. The Lettermint route acts as an event bus, not a pipe.
- **Self-reinforcing threading**: Operator replies through a project-specific outbound route cause customer replies to arrive at the corresponding project-specific inbound route.

---

## Task 80: Contact Email Uniqueness

**Decision:** `UNIQUE(email, organization_id)` — per-org contact identity, not global.

**Primary routing path (project-specific route):**
1. Message arrives at a project-specific callback URL.
2. Route context provides org + project. SenderMatcher resolves contact within that org scope only.
3. Single-result lookup guaranteed by the composite unique constraint.
4. No ambiguity possible.

**Fallback path (catchall route, multi-org contact):**
1. Message arrives at the catchall.
2. SenderMatcher finds multiple contacts across orgs for the sender email.
3. Message held in limbo (thread with `organization_id = NULL`, `source: disambiguation`).
4. Disambiguation DM sent via Lettermint outbound route listing the sender's active projects/orgs with their specific inbound addresses.
5. Sender replies to the appropriate project address (resolving via normal project-route path) or replies directly to the DM (resolved by disambiguation webhook).
6. Original held message is then routed to the correct org/project. No resend needed.

**DM thread model:** Uses existing Thread model with nullable `organization_id` and `source: disambiguation`. Once resolved, thread gets assigned to the correct org and transitions into normal flow.

**TTL on disambiguation:** 72 hours (configurable). After expiry, surfaced to operator as "unresolvable, needs manual routing."

**Migration:** Safe. Existing data has one email per org, so the composite constraint is satisfied. All `Contact.find_by(email:)` calls become `Contact.where(email:)` with multi-result handling, but SenderMatcher is being rewritten to use route context as the first signal anyway.

**Idempotency:** `email_message_id` as deduplication key on thread creation. Each webhook consumer needs its own idempotency strategy (enrichment is naturally idempotent; notification needs a "sent" flag; audit is append-only with message ID for dedup at query time).

---

## Task 77: Organization Domain Uniqueness

**Decision:** `UNIQUE(domain) WHERE domain IS NOT NULL` (Postgres partial index). `custom_domain` also `UNIQUE` unconditionally.

**Rationale:** Per-project routes make domain-based sender matching a tier-4 fallback, not a primary routing signal. The priority order for SenderMatcher:

1. **Route context** — project or org-general route provides org directly.
2. **Contact match within route's org scope** — single-result via composite unique constraint.
3. **Global contact match** (catchall only) — multiple results trigger disambiguation DM.
4. **Domain match** (catchall, unknown sender) — falls back to domain lookup. Uniqueness constraint guarantees single result.

Domain uniqueness prevents data quality issues at org creation time. Multiple orgs sharing a domain would cause every unknown sender from that domain to route ambiguously. NULL domain allowed for internal projects (v2).

---

## Task 106: Thread-Project Relationship

**Decision:** Direct optional FK `threads.project_id`, reversing earlier recommendation for indirect-only relationship.

**Rationale:** Per-project routes provide a reliable automated signal for the thread-project link. Without per-project routes, the link required operator judgment. With them, the inbound channel carries the context.

**Flow:**
- Project-specific route → thread created with both `organization_id` and `project_id` set from route context.
- Org-general route → thread created with `organization_id` from route, `project_id = NULL`.
- Catchall route → thread created from sender matching, `project_id = NULL`.
- Tasks retain dual ownership (`thread_id` and `project_id`). Tasks from project-routed threads inherit project context automatically.

**Query for "threads related to this project":**
```sql
-- Direct (route-based association)
SELECT * FROM threads WHERE project_id = ?
UNION
-- Indirect (operator-linked tasks from catchall threads)
SELECT c.* FROM threads c
  JOIN tasks t ON t.thread_id = c.id
  WHERE t.project_id = ? AND c.project_id IS NULL
```

---

## Multi-Webhook Architecture

Each Lettermint route registers multiple webhooks, decomposing SenderMatcher's responsibilities:

| Purpose | Behavior | Blocking? |
|---------|----------|-----------|
| sender_matching | Identity resolution, thread creation, org/project assignment | First to fire, creates the thread |
| enrichment | Urgency scoring, keyword extraction, attachment classification | Async, updates thread metadata after creation |
| notification | Operator ping (Slack, push, email) | Async, independent |
| audit | Append-only activity log entry | Async, tolerates duplicates |
| disambiguation | Sends DM email to ambiguous sender | Only on disambiguation-state threads |

**Eventual consistency:** A thread may appear in the attention queue before enrichment completes. Initial score uses signals available at creation (org tier from route, contact history, "new" state). Enrichment updates urgency and keyword signals seconds later. Queue re-sort is debounced to avoid jarring reorders while operator is reading.

**Default webhook set per route type:**
- Project route: sender_matching, enrichment, notification, audit
- Org-general route: sender_matching, enrichment, notification, audit
- Disambiguation route: disambiguation (single webhook)
- Catchall route: sender_matching, enrichment, notification, audit

---

## Schema Additions

```
inbound_routes
├── id: uuid (PK)
├── lettermint_route_id: text (external reference)
├── callback_token: text (UNIQUE, URL-embedded identifier)
├── organization_id: uuid (FK → organizations, NOT NULL)
├── project_id: uuid (FK → projects, nullable)
├── route_type: enum (general, project, disambiguation)
├── created_at, updated_at: timestamptz

inbound_route_webhooks
├── id: uuid (PK)
├── inbound_route_id: uuid (FK → inbound_routes)
├── lettermint_webhook_id: text (external reference)
├── endpoint_url: text
├── purpose: enum (sender_matching, enrichment, notification, audit, disambiguation)
├── enabled: boolean DEFAULT true
├── created_at, updated_at: timestamptz
```

**Changes to existing SDD entities:**
- `threads.organization_id`: becomes nullable (for disambiguation-state threads)
- `threads.project_id`: new nullable FK (set from route context when available)
- `threads.source` enum: add `disambiguation` value
- `contacts` unique constraint: change from `UNIQUE(email)` to `UNIQUE(email, organization_id)`
- `organizations.domain`: add `UNIQUE WHERE domain IS NOT NULL` partial index
- `organizations.custom_domain`: add `UNIQUE` constraint
- `messages.delivery_status`: new enum (pending, sent, delivered, bounced, suppressed, failed) for outbound email tracking
- `messages.lettermint_message_id`: external ID returned by Lettermint API, used to correlate webhook events

---

## Lettermint Outbound Email Status Webhooks

**Decision:** Track email delivery status via Lettermint webhooks, stored on the Message record.

**Rationale:** Lettermint sends webhook callbacks for email lifecycle events (created, sent, delivered, bounced, returned, suppressed). Without this visibility, operators cannot know if their replies reached the customer. Bounce information is operationally critical — it signals that the contact's email may be invalid.

**Flow:**
1. Operator sends reply → Swoosh delivers via Lettermint adapter → Lettermint returns `message_id`
2. Store `lettermint_message_id` on Message, set `delivery_status: :pending`
3. Lettermint POSTs status updates to `/webhook/email-status`
4. Match incoming `message_id` to stored `lettermint_message_id`, update `delivery_status`
5. Bounce/suppression events optionally flag the Contact for review

**Endpoint:** `POST /webhook/email-status` — separate from inbound mail webhook (`/webhook/inbound`). Uses same `WEBHOOK_TOKEN` authentication or a dedicated token.

**Status values:**
| Lettermint Event | delivery_status |
|------------------|-----------------|
| created | pending |
| sent | sent |
| delivered | delivered |
| bounced | bounced |
| returned | bounced |
| suppressed | suppressed |

**UI implications:** Outbound messages in the thread show a delivery indicator (checkmark, warning icon for bounces). Critical bounces surface in the attention queue or trigger operator notification.
