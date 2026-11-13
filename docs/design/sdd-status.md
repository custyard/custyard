# SDD v0.4 Implementation Status

Planning & Implementation State

> **Partially historical.** Sections below marked with a dated correction were
> verified against the code on 2026-07-25. Key Files, the Technical
> Architecture and Data Model tables, the scoring list, US-6, US-10, the
> security list and What's Next were re-checked against `main` on 2026-10-26.
> The user-story table and the remaining acceptance criteria have not been
> re-verified. `docs/design/spec-public-intake.md` and its design-decisions
> companion are current and authoritative for the intake path;
> `docs/design/spec-inbound-channels.md` is for inbound email.

## Key Files

Planning Artifacts:

- docs/design/sdd.md - Complete SDD (v0.4) with US-1 through US-11 specs, technical architecture, data model, and activation flow
- wireframes/operator-wireframe-v0.3.jsx - Interactive operator interface prototype
- wireframes/portal-wireframe-v0.3.jsx - Client portal prototype
- wireframes/\*.png (6 files) - Implementation screenshots from Mar 22

Core Implementation:

- lib/custyard/threads.ex - Thread CRUD, state transitions, attention queue queries
- lib/custyard/scoring.ex - Composite scoring algorithm with breakdown/transparency
- lib/custyard/scoring/scheduler.ex - Background recalculation (5-min interval), dormancy checks, neglect notifications
- lib/custyard/scoring/recalculator.ex - Batch score recalculation (100-thread batches)
- lib/custyard/email/parser.ex - RFC 5322 parsing, MIME multipart, charset handling
- lib/custyard/email/processor.ex - Email workflow orchestration (webhook payloads, sender matching, threading)
- lib/custyard/email/lmtp_server.ex - LMTP server with STARTTLS, rate limiting
- lib/custyard/email/imap_pollers.ex, imap_poll.ex - per-channel IMAP polling (inbound-channels Phase 3)
- lib/custyard/email/sender_matcher.ex - Contact/org matching, on-demand creation, unmatched handling
- lib/custyard/email/thread_matcher.ex - In-Reply-To/References header threading
- lib/custyard/email/sieve_header_mapper.ex - Sieve-injected header → thread property mapping
- lib/custyard/notifications/neglect_checker.ex - Threshold breach detection, transition-based notifications
- lib/custyard/notifications/email.ex - Neglect alert email delivery (Swoosh)
- lib/custyard/threads/dormancy_checker.ex - Automatic waiting → dormant transitions
- lib/custyard_web/live/staff/\*.ex - Attention queue, neglect report, org/project management, thread detail
- lib/custyard_web/live/portal/\*.ex - Customer portal with requests, projects, threads

Security:

- lib/custyard_web/plugs/require_operator.ex - Operator session validation
- lib/custyard_web/plugs/portal_auth.ex - Org token/custom domain validation
- lib/custyard/webhooks/signature.ex - Per-source HMAC signature verification for inbound webhooks (`WEBHOOK_SECRET_LETTERMINT`, `_ZENDESK`, `_INTERCOM`, `_SLACK`), with per-adapter digests under lib/custyard/webhooks/adapters/
- lib/custyard/rate_limit.ex, lib/custyard_web/plugs/public_rate_limit.ex - ETS sliding-window rate limiter with named buckets in `config/config.exs` (operator login: 5/60s per IP, 5/hour per email)
- lib/custyard_web/plugs/custom_domain.ex - Custom domain → org resolution with path rewriting

## Implementation Status

### User Stories

| User Story | Feature                                | Status |
| ---------- | -------------------------------------- | ------ |
| US-1       | Inbound email creates a thread   | Done   |
| US-2       | Sieve pre-routing injects metadata     | Done   |
| US-3       | Lightweight thread state model   | Done   |
| US-4       | Threads spawn tasks              | Done   |
| US-5       | Attention queue with composite scoring | Done   |
| US-6       | Neglect alerts and thresholds          | Done   |
| US-7       | Customer portal (view, file, reply)    | Done   |
| US-8       | White-label portal branding            | Done   |
| US-9       | Organization unified timeline          | Done   |
| US-10      | Projects with templates                | Done   |
| US-11      | Internal projects                      | Done   |

### Technical Architecture (SDD §3)

| Component                    | Implementation                                                                                            | Status  |
| ---------------------------- | --------------------------------------------------------------------------------------------------------- | ------- |
| Email Ingestion Pipeline     | LMTP server, per-channel IMAP, Lettermint webhook (forwarding and direct-MX channels). All paths converge on the webhook dispatcher | Done    |
| Attention Scoring Engine     | Scoring module with idle/state/tier/urgency/velocity/neglect components plus a per-channel bonus. Scheduler runs every 5 min. | Done    |
| Authentication (Operator)    | **Corrected 2026-07-25:** magic-link only — `POST /login` emails a 15-minute single-use token, `GET /login/verify/:token` establishes the session. Rate-limited, timing-attack safe. `password_hash` (Argon2) survives on the schema and is still written by `mix dev.reset_operator_password`, but no route consumes it; there is no password login path. | Done    |
| Authentication (Portal)      | Token-based URL + custom domain. No Rodauth/SSO yet — SDD specifies Rodauth email/password + optional SSO | Partial |
| Background Processing        | Supervised GenServers, each switchable by config: scoring scheduler (scores, dormancy, neglect), outbound mail queue, intake sweeps (slug claim expiry, retention sweep), per-channel IMAP pollers, and the optional LMTP server and acknowledgment consumer | Done    |
| Operator/Customer Isolation  | Separate route scopes, plugs, LiveView on_mount hooks. No shared auth.                                    | Done    |
| Cross-Organization Isolation | All portal queries filter by org_id from authenticated session                                            | Done    |
| Email as Untrusted Input     | Plain-text bodies, plus HTML sanitised at ingest with an allowlist (`Custyard.Email.HtmlSanitizer`). Remote images are removed; `cid:` images are kept and resolved at render time to the same message's stored attachments (`CustyardWeb.InlineImages`). Phoenix template escaping prevents XSS | Done    |
| Data at Rest Encryption      | Not implemented — using SQLite for MVP. Only IMAP channel passwords are encrypted (`Custyard.Credentials`, AES-256-GCM) | Not Yet |
| Inbound Channels             | Inbound-channels Phases 0–3. An operator-visible `InboundChannel` per public support address under a route, with lifecycle pending_verification → awaiting_first_message → active (+ paused/revoked), a triage stage (own echo, provider verification capture, auto-response, suspect, operator-sent, manual-forward unwrap) ahead of sender matching, per-channel reply identity with a Lettermint sending-domain check, a quiet-channel alert, a 14-day rejection log, and a channels tab with a setup wizard. Three ingress kinds: forwarding to `local+token@<route-id>.lettermint.app` (Proton, Gmail, Google Workspace admin routing, other), direct MX on the route's custom domain, and per-channel IMAP with the password encrypted under `CREDENTIAL_ENCRYPTION_KEY`. Phase 2 added CC and Reply-To, sanitised HTML, attachments, the archive copy, CC-participant DSAR and language detection. Open items: spec-inbound-channels, Implementation status. Spec: `docs/design/spec-inbound-channels.md`. | Done |
| Outbound Email               | Platform-native outbound implemented (#26 merged): operator replies compose in-platform, send threaded via Lettermint, tracked send-side (pending/sent/failed). Provider status webhook landed (inbound-channels Phase 0): `POST /api/webhook/email-status/lettermint` advances delivered/bounced/suppressed/failed with rank-ordered transitions and an audit event per transition. | Done |

### Data Model (SDD §4)

| Entity            | Implementation Notes                                                                           | Status  |
| ----------------- | ---------------------------------------------------------------------------------------------- | ------- |
| Organization      | name, domain, tier, token, branding fields, custom_domain. Unique indices on token/domain.     | Done    |
| Contact           | email, name, is_admin, email_status (valid/bounced/suppressed, from delivery events). Composite unique (email, org_id). No portal account yet. | Done    |
| Thread      | Full state model, urgency, cached_score, snoozed_until, last_neglect_notification. No tags substrate (SDD §4.1 freeform labels). | Partial |
| Message           | source, origin, sender_email, body, html_body, to/cc addresses, reply_to, message_id, in_reply_to, delivery_status, triage_class, authentication, is_internal_note, deleted_at; inserted_at and updated_at. Per-recipient delivery in `message_recipient_statuses`. | Done    |
| Attachment        | `message_attachments` (inbound-channels Phase 2): content stored in the database (`Custyard.Files`), keyed by SHA-256 per tenant, sniffed type, per-channel cap, authenticated operator and portal download. Outbound attachments not yet. | Partial |
| Task              | title, state, portal_visible, due_at. FK to thread and project.                          | Done    |
| Project           | title, description, dates, portal_visible, project_type, tags, is_template.                    | Done    |
| Project Template  | is_template flag on Project. Template instantiation with date calculation.                     | Done    |
| Activity Log      | `audit_events` (`Custyard.AuditEvent`) is an append-only log of webhook processing, delivery-status changes, replies and notes, thread state changes, ignored senders, prospect conversion, slug release, channel changes, staff accounts and acknowledgments. Tenant admins read it at `/app/settings/audit` and instance admins read installation events at `/admin/audit` (`Custyard.AuditLog`). Snooze, the suspect flag, labels, tasks and automatic state transitions are not recorded. It does not feed the organization timeline the SDD describes. | Partial |
| Neglect Threshold | Stored in Settings schema (JSON column), per-tier warning/critical hours.                      | Done    |
| Operator Account  | email, role, organization_id, login_token + login_token_expires_at (magic link). password_hash (Argon2) present but unused by any login route — see the Authentication (Operator) row. | Done    |
| Portal Account    | Not implemented as separate entity — portal access uses org token, not per-contact accounts.   | Not Yet |
| Settings          | Single-row schema with score_weights, neglect_thresholds, sieve_header_mappings, intake_config, branding. | Done    |

### Scoring Algorithm (SDD §4.3)

All scoring components implemented per spec:

- Idle time: log(hours+1)×10, capped at 40
- State scores: new=30, active=15, waiting=0, dormant=25, resolved=0
- Tier scores: enterprise=20, standard=10, basic=5
- Urgency bonuses: urgent=15, elevated=7, normal=0
- Velocity: log(24h_message_count+1)×3, capped at 10
- Neglect bonus: critical=15, warning=7, ok=0
- Channel bonus: 0–30 per inbound channel, set on the channel card, not weighted
- Snooze: excluded from queue entirely
- Transparency: `Scoring.breakdown/1` shows component-level score explanation
- All weights configurable via Settings without code changes

### Acceptance Criteria Coverage

US-1 (Email → Thread):

- [x] Sender matched to Contact → links to Contact and Organization
- [x] Unknown sender, known domain → links to Organization with flag
- [x] Entirely unknown sender → "unmatched" queue
- [x] Subject → title, body → first message
- [x] In-Reply-To/References threading
- [x] No mandatory fields beyond email content

US-2 (Sieve Pre-routing):

- [x] Reads configurable custom headers
- [x] Maps header values to thread properties (tier, urgency)
- [x] Purely additive — works correctly with no custom headers

US-3 (State Model):

- [x] States: New, Active, Waiting, Dormant, Resolved
- [x] New → Active on operator view/response
- [x] Operator-initiated → Waiting
- [x] Automatic → Dormant (tier-specific thresholds)
- [x] Inbound message on Dormant/Resolved → Active
- [x] No substates in MVP

US-4 (Tasks):

- [x] Title, due date, portal visibility
- [x] Thread can have zero or many tasks
- [x] States: Open, In Progress, Done
- [x] Task completion does not auto-resolve thread
- [ ] Effort estimate field (not implemented)
- [ ] Description field (not implemented)

US-5 (Attention Queue):

- [x] Default landing page for operator
- [x] Shows org name, contact, title, time since last action, state
- [x] Near-real-time updates via PubSub
- [x] Snooze (dismiss for N hours/days)
- [x] Transparent scoring (breakdown tooltips)
- [x] State filtering (all/new/active/waiting/dormant)
- [ ] Tag filtering

US-6 (Neglect Alerts):

- [x] Configurable thresholds per tier
- [x] Email notifications via Swoosh when `EMAIL_NOTIFICATIONS_ENABLED=true`; logged otherwise
- [x] Visual indicator in attention queue
- [x] Neglect report view grouped by organization
- [x] Transition-based notification (no duplicates)

US-7 (Client Portal):

- [x] Scoped to organization (no cross-org visibility)
- [x] File new requests (title + description)
- [x] View threads with state and last activity
- [x] Reply to existing threads
- [x] View portal-visible tasks
- [ ] Per-contact authentication (uses org token instead of Rodauth)
- [ ] Admin vs non-admin contact visibility scoping

US-8 (White-label Branding):

- [x] Logo URL and primary/secondary color per org
- [x] Custom domain support via CNAME with DNS verification
- [x] Platform branding not shown unless chosen
- [x] Custom domain path rewriting at plug level

US-9 (Organization View):

- [x] All threads grouped by state
- [x] Contact list
- [x] Organization metadata (tier, domain, branding)
- [x] One-click navigation from thread → organization
- [ ] Unified activity timeline (no ActivityLog entity yet)
- [ ] Freeform notes / custom fields
- [ ] Search within organization scope

US-10 (Projects with Templates):

- [x] Title, description, dates, task list
- [x] Templates with is_template flag
- [x] Portal visibility (per-project and per-task)
- [x] Project linked to thread (optional)
- [x] No "project completion" lifecycle state
- [x] Template instantiation with relative → absolute date conversion (`Projects.create_from_template/3` keeps each task's offset from the template's start date)

US-11 (Internal Projects):

- [x] Projects with project_type: :internal, no org link
- [x] Never portal-visible
- [x] Tags for categorization (oss-library, experiment, web-tool)
- [x] Same task model as customer projects
- [ ] Internal project tasks in attention queue scoring (tasks scored independently from projects)

### QA & Security Hardening

CI (`.github/workflows/ci.yml`) runs on every PR: `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix test`, `mix credo --strict`, `mix sobelow --exit`, `mix hex.audit` and `mix deps.audit`. Test counts are not tracked here.

Security measures in place:

- Magic-link operator login: single-use token, 15-minute TTL, constant-time comparison (`Plug.Crypto.secure_compare`), cleared on use
- Login rate limiting (5 attempts / 60s per IP, 5 / hour per email)
- Per-source HMAC webhook signature verification (secure_compare) — replaced the single bearer token this document originally described
- Session renewal on login
- CSRF protection on all browser routes
- HTML email bodies sanitised with an allowlist; remote images removed (see Email as Untrusted Input)
- Logo path validation: same-origin `/uploads/` paths only, no traversal (`Custyard.UploadPath`)
- Domain format validation, color format validation
- Sieve header value whitelist validation

## What's Next (Not Yet Built)

As of 2026-10-26. Email infrastructure, production deployment and webhook ingestion (onetimesecret/custyard#10, #11, #13) are closed.

1. **Onetime Secret pilot** of inbound channels: one forwarding `support@` channel, plus a first real message on direct MX and on Workspace admin routing (spec-inbound-channels, Implementation status). It depends on the production config pass in [custyard/custyard#6](https://github.com/custyard/custyard/issues/6).
2. **Outbound reply attachments** - inbound attachments and their downloads are done; a reply cannot carry a file.
3. [onetimesecret/custyard#12](https://github.com/onetimesecret/custyard/issues/12) **Team Support** - `teams` and operator roles (super_admin/admin/agent) exist; there is no team or operator-management UI and no conversation assignment ([custyard/custyard#2](https://github.com/custyard/custyard/issues/2) §6).
4. [onetimesecret/custyard#14](https://github.com/onetimesecret/custyard/issues/14) **Encryption at Rest** - only IMAP channel passwords are encrypted.
5. [custyard/custyard#11](https://github.com/custyard/custyard/issues/11) **Metrics consumer** - `CustyardWeb.Telemetry.metrics/0` declares metrics that no reporter reads.
6. Public-intake work that waits for real traffic: attribution, intake observability, conversion into an existing organization with a portal invite, and abuse controls ([custyard/custyard#2](https://github.com/custyard/custyard/issues/2) §6).

### SDD Items Not Yet Implemented

- **Portal Account entity** (SDD §4.1) - Per-contact authentication with Rodauth. Currently using org-level token auth instead of individual contact accounts.
- **Activity Log entity** (SDD §4.1) - Append-only log for organization timeline and audit trail. Organization timeline view exists but without dedicated log table.
- **Attachment entity** (SDD §4.1) - Inbound side done in inbound-channels Phase 2 (`Custyard.MessageAttachment`, `Custyard.Attachments`). Portal download followed. Outbound reply attachments remain.
- ~~**Outbound delivery-status webhook** (SDD §5.2)~~ - Done in inbound-channels Phase 0: `Custyard.Email.DeliveryStatus` applies Lettermint lifecycle events to `messages.delivery_status` (rank rule, terminal states, `:withheld` and inbound rows never touched), writes a `:delivery_status_updated` audit event, and the thread view shows delivered/suppressed indicators. Secret: `WEBHOOK_SECRET_LETTERMINT_STATUS`. Bounced and suppressed replies flag the recipient contact (`contacts.email_status`) and send the operator a notice; a later delivery clears the flag. Delivery is tracked per recipient (`message_recipient_statuses`): the message indicator follows the To address, a failed CC is listed under the message, and the notice goes out once per failed recipient.
- **Task effort estimate / description fields** (SDD §4.1) - Task schema has title, state, due_at, portal_visible but not effort_estimate or description.
- **Organization notes and custom fields** (SDD §4.1) - Not on Organization schema.
- **Organization-scoped search** (SDD US-9) - No search implementation.
- **Tag filtering in attention queue** (SDD US-5) - Threads have no tags substrate (tags exist only on projects) and the queue has no filter UI.
