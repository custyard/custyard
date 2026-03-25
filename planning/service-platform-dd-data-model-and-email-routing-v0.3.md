# Design Decisions: Data Model + Lettermint Integration

**Date:** 2026-03-24
**Context:** Supplements SDD v0.2Th. Captures decisions made during design review of Tasks 80, 77, 106 in light of Lettermint's per-project routes and multiple webhooks per route.

---

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
3. Message held in limbo (conversation with `organization_id = NULL`, `source: disambiguation`).
4. Disambiguation DM sent via Lettermint outbound route listing the sender's active projects/orgs with their specific inbound addresses.
5. Sender replies to the appropriate project address (resolving via normal project-route path) or replies directly to the DM (resolved by disambiguation webhook).
6. Original held message is then routed to the correct org/project. No resend needed.

**DM conversation model:** Uses existing Conversation model with nullable `organization_id` and `source: disambiguation`. Once resolved, conversation gets assigned to the correct org and transitions into normal flow.

**TTL on disambiguation:** 72 hours (configurable). After expiry, surfaced to operator as "unresolvable, needs manual routing."

**Migration:** Safe. Existing data has one email per org, so the composite constraint is satisfied. All `Contact.find_by(email:)` calls become `Contact.where(email:)` with multi-result handling, but SenderMatcher is being rewritten to use route context as the first signal anyway.

**Idempotency:** `email_message_id` as deduplication key on conversation creation. Each webhook consumer needs its own idempotency strategy (enrichment is naturally idempotent; notification needs a "sent" flag; audit is append-only with message ID for dedup at query time).

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

## Task 106: Conversation-Project Relationship

**Decision:** Direct optional FK `conversations.project_id`, reversing earlier recommendation for indirect-only relationship.

**Rationale:** Per-project routes provide a reliable automated signal for the conversation-project link. Without per-project routes, the link required operator judgment. With them, the inbound channel carries the context.

**Flow:**
- Project-specific route → conversation created with both `organization_id` and `project_id` set from route context.
- Org-general route → conversation created with `organization_id` from route, `project_id = NULL`.
- Catchall route → conversation created from sender matching, `project_id = NULL`.
- Tasks retain dual ownership (`conversation_id` and `project_id`). Tasks from project-routed conversations inherit project context automatically.

**Query for "conversations related to this project":**
```sql
-- Direct (route-based association)
SELECT * FROM conversations WHERE project_id = ?
UNION
-- Indirect (operator-linked tasks from catchall conversations)
SELECT c.* FROM conversations c
  JOIN tasks t ON t.conversation_id = c.id
  WHERE t.project_id = ? AND c.project_id IS NULL
```

---

## Multi-Webhook Architecture

Each Lettermint route registers multiple webhooks, decomposing SenderMatcher's responsibilities:

| Purpose | Behavior | Blocking? |
|---------|----------|-----------|
| sender_matching | Identity resolution, conversation creation, org/project assignment | First to fire, creates the conversation |
| enrichment | Urgency scoring, keyword extraction, attachment classification | Async, updates conversation metadata after creation |
| notification | Operator ping (Slack, push, email) | Async, independent |
| audit | Append-only activity log entry | Async, tolerates duplicates |
| disambiguation | Sends DM email to ambiguous sender | Only on disambiguation-state conversations |

**Eventual consistency:** A conversation may appear in the attention queue before enrichment completes. Initial score uses signals available at creation (org tier from route, contact history, "new" state). Enrichment updates urgency and keyword signals seconds later. Queue re-sort is debounced to avoid jarring reorders while operator is reading.

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
- `conversations.organization_id`: becomes nullable (for disambiguation-state conversations)
- `conversations.project_id`: new nullable FK (set from route context when available)
- `conversations.source` enum: add `disambiguation` value
- `contacts` unique constraint: change from `UNIQUE(email)` to `UNIQUE(email, organization_id)`
- `organizations.domain`: add `UNIQUE WHERE domain IS NOT NULL` partial index
- `organizations.custom_domain`: add `UNIQUE` constraint
