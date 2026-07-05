# SDD v0.3 Implementation Status

Planning & Implementation State

## Key Files

Planning Artifacts:

- docs/design/sdd.md - Complete SDD (v0.3) with US-1 through US-11 specs, technical architecture, data model, and activation flow
- planning/operator-wireframe-v0.3.jsx - Interactive operator interface prototype
- planning/portal-wireframe-v0.3.jsx - Client portal prototype
- planning/\*.png (6 files) - Implementation screenshots from Mar 22

Core Implementation:

- lib/custyard/conversations.ex - Conversation CRUD, state transitions, attention queue queries
- lib/custyard/scoring.ex - Composite scoring algorithm with breakdown/transparency
- lib/custyard/scoring/scheduler.ex - Background recalculation (5-min interval), dormancy checks, neglect notifications
- lib/custyard/scoring/recalculator.ex - Batch score recalculation (100-conversation batches)
- lib/custyard/email/parser.ex - RFC 5322 parsing, MIME multipart, charset handling
- lib/custyard/email/processor.ex - Email workflow orchestration (webhook payloads, sender matching, threading)
- lib/custyard/email/lmtp_server.ex - LMTP server with STARTTLS, rate limiting
- lib/custyard/email/imap_poller.ex - IMAP polling GenServer
- lib/custyard/email/sender_matcher.ex - Contact/org matching, on-demand creation, unmatched handling
- lib/custyard/email/thread_matcher.ex - In-Reply-To/References header threading
- lib/custyard/email/sieve_header_mapper.ex - Sieve-injected header → conversation property mapping
- lib/custyard/notifications/neglect_checker.ex - Threshold breach detection, transition-based notifications
- lib/custyard/notifications/email.ex - Neglect alert email delivery (Swoosh)
- lib/custyard/conversations/dormancy_checker.ex - Automatic waiting → dormant transitions
- lib/custyard_web/live/operator/\*.ex - Attention queue, neglect report, org/project management, conversation detail
- lib/custyard_web/live/portal/\*.ex - Customer portal with requests, projects, conversations

Security:

- lib/custyard_web/plugs/require_operator.ex - Operator session validation
- lib/custyard_web/plugs/portal_auth.ex - Org token/custom domain validation
- lib/custyard_web/plugs/webhook_auth.ex - Bearer token for webhook endpoint
- lib/custyard_web/plugs/login_rate_limit.ex - ETS-based rate limiting (5/60s per IP)
- lib/custyard_web/plugs/custom_domain.ex - Custom domain → org resolution with path rewriting

## Implementation Status

### User Stories

| User Story | Feature                                | Status |
| ---------- | -------------------------------------- | ------ |
| US-1       | Inbound email creates a conversation   | Done   |
| US-2       | Sieve pre-routing injects metadata     | Done   |
| US-3       | Lightweight conversation state model   | Done   |
| US-4       | Conversations spawn tasks              | Done   |
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
| Email Ingestion Pipeline     | LMTP server, IMAP poller, HTTP webhook. Three ingestion paths converge on Processor for unified handling  | Done    |
| Attention Scoring Engine     | Scoring module with idle/state/tier/urgency/velocity/neglect components. Scheduler runs every 5 min.      | Done    |
| Authentication (Operator)    | Email/password + Argon2, session-based, rate-limited login, timing-attack safe                            | Done    |
| Authentication (Portal)      | Token-based URL + custom domain. No Rodauth/SSO yet — SDD specifies Rodauth email/password + optional SSO | Partial |
| Background Processing        | Scoring scheduler, dormancy checker, neglect checker all running as GenServers                            | Done    |
| Operator/Customer Isolation  | Separate route scopes, plugs, LiveView on_mount hooks. No shared auth.                                    | Done    |
| Cross-Organization Isolation | All portal queries filter by org_id from authenticated session                                            | Done    |
| Email as Untrusted Input     | HTML stripped to plain text, Phoenix template escaping prevents XSS                                       | Done    |
| Data at Rest Encryption      | Not implemented — using SQLite for MVP                                                                    | Not Yet |
| Outbound Email (v1.1)        | Not implemented — operator responds via own email client per MVP design                                   | Not Yet |

### Data Model (SDD §4)

| Entity            | Implementation Notes                                                                           | Status  |
| ----------------- | ---------------------------------------------------------------------------------------------- | ------- |
| Organization      | name, domain, tier, token, branding fields, custom_domain. Unique indices on token/domain.     | Done    |
| Contact           | email, name, is_admin. Composite unique (email, org_id). No portal account yet.                | Done    |
| Conversation      | Full state model, urgency, cached_score, snoozed_until, last_neglect_notification.             | Done    |
| Message           | source, sender_email, body, is_internal_note, message_id, in_reply_to. No updated_at.          | Done    |
| Attachment        | Upload plug exists (Plug.Static for /uploads/), but no Attachment schema/migration per SDD §4. | Partial |
| Task              | title, state, portal_visible, due_at. FK to conversation and project.                          | Done    |
| Project           | title, description, dates, portal_visible, project_type, tags, is_template.                    | Done    |
| Project Template  | is_template flag on Project. Template instantiation with date calculation.                     | Done    |
| Activity Log      | Not implemented — SDD specifies append-only log for organization timeline and audit.           | Not Yet |
| Neglect Threshold | Stored in Settings schema (JSON column), per-tier warning/critical hours.                      | Done    |
| Operator Account  | email, password_hash (Argon2).                                                                 | Done    |
| Portal Account    | Not implemented as separate entity — portal access uses org token, not per-contact accounts.   | Not Yet |
| Settings          | Single-row schema with score_weights, neglect_thresholds, sieve_header_mappings.               | Done    |

### Scoring Algorithm (SDD §4.3)

All scoring components implemented per spec:

- Idle time: log(hours+1)×10, capped at 40
- State scores: new=30, active=15, waiting=0, dormant=25, resolved=0
- Tier scores: enterprise=20, standard=10, basic=5
- Urgency bonuses: urgent=15, elevated=7, normal=0
- Velocity: log(24h_message_count+1)×3, capped at 10
- Neglect bonus: critical=15, warning=7, ok=0
- Snooze: excluded from queue entirely
- Transparency: `Scoring.breakdown/1` shows component-level score explanation
- All weights configurable via Settings without code changes

### Acceptance Criteria Coverage

US-1 (Email → Conversation):

- [x] Sender matched to Contact → links to Contact and Organization
- [x] Unknown sender, known domain → links to Organization with flag
- [x] Entirely unknown sender → "unmatched" queue
- [x] Subject → title, body → first message
- [x] In-Reply-To/References threading
- [x] No mandatory fields beyond email content

US-2 (Sieve Pre-routing):

- [x] Reads configurable custom headers
- [x] Maps header values to conversation properties (tier, urgency)
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
- [x] Conversation can have zero or many tasks
- [x] States: Open, In Progress, Done
- [x] Task completion does not auto-resolve conversation
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
- [x] Email notifications (Swoosh stub)
- [x] Visual indicator in attention queue
- [x] Neglect report view grouped by organization
- [x] Transition-based notification (no duplicates)

US-7 (Client Portal):

- [x] Scoped to organization (no cross-org visibility)
- [x] File new requests (title + description)
- [x] View conversations with state and last activity
- [x] Reply to existing conversations
- [x] View portal-visible tasks
- [ ] Per-contact authentication (uses org token instead of Rodauth)
- [ ] Admin vs non-admin contact visibility scoping

US-8 (White-label Branding):

- [x] Logo URL and primary/secondary color per org
- [x] Custom domain support via CNAME with DNS verification
- [x] Platform branding not shown unless chosen
- [x] Custom domain path rewriting at plug level

US-9 (Organization View):

- [x] All conversations grouped by state
- [x] Contact list
- [x] Organization metadata (tier, domain, branding)
- [x] One-click navigation from conversation → organization
- [ ] Unified activity timeline (no ActivityLog entity yet)
- [ ] Freeform notes / custom fields
- [ ] Search within organization scope

US-10 (Projects with Templates):

- [x] Title, description, dates, task list
- [x] Templates with is_template flag
- [x] Portal visibility (per-project and per-task)
- [x] Project linked to conversation (optional)
- [x] No "project completion" lifecycle state
- [ ] Template instantiation with relative → absolute date conversion (partially — is_template exists but instantiation logic unclear)

US-11 (Internal Projects):

- [x] Projects with project_type: :internal, no org link
- [x] Never portal-visible
- [x] Tags for categorization (oss-library, experiment, web-tool)
- [x] Same task model as customer projects
- [ ] Internal project tasks in attention queue scoring (tasks scored independently from projects)

### QA & Security Hardening

496 tests across 25 test files, 0 failures.

Recent QA work (qa/batch1-security-and-validation-fixes):

- CSRF protection: removed GET /logout route (Sobelow finding)
- Credo strict: reduced complexity and nesting depth
- Format compliance: mix format --check-formatted passing
- Input validation tightened across codebase
- Portal path generation fixed to always use token-based routes

Security measures in place:

- Argon2 password hashing with constant-time comparison
- Login rate limiting (5 attempts / 60s per IP)
- Webhook bearer token authentication (secure_compare)
- Session renewal on login
- CSRF protection on all browser routes
- HTML email bodies stripped to plain text
- File upload path validation (restricts to /uploads/ or https://)
- Domain format validation, color format validation
- Sieve header value whitelist validation

## What's Next (Not Yet Built)

1. [#10](https://github.com/onetimesecret/custyard/issues/10) **Email Infrastructure** - LMTP/IMAP code exists but needs MTA hookup for real deployment
2. [#11](https://github.com/onetimesecret/custyard/issues/11) **Production Deployment** - Containerfile exists but untested
3. [#12](https://github.com/onetimesecret/custyard/issues/12) **Team Support** - Multi-operator roles and permissions
4. [#13](https://github.com/onetimesecret/custyard/issues/13) **Webhook Ingestion** - Controller exists, needs full integration
5. [#14](https://github.com/onetimesecret/custyard/issues/14) **Encryption at Rest** - Architecture defined, using SQLite for MVP

### SDD Items Not Yet Implemented

- **Portal Account entity** (SDD §4.1) - Per-contact authentication with Rodauth. Currently using org-level token auth instead of individual contact accounts.
- **Activity Log entity** (SDD §4.1) - Append-only log for organization timeline and audit trail. Organization timeline view exists but without dedicated log table.
- **Attachment entity** (SDD §4.1) - File upload infrastructure exists but no Attachment schema linked to Message.
- **Outbound Email** (SDD §5.2, v1.1) - Platform does not send email. Operator responds via own email client per MVP design.
- **Task effort estimate / description fields** (SDD §4.1) - Task schema has title, state, due_at, portal_visible but not effort_estimate or description.
- **Organization notes and custom fields** (SDD §4.1) - Not on Organization schema.
- **Organization-scoped search** (SDD US-9) - No search implementation.
- **Tag filtering in attention queue** (SDD US-5) - Tags exist on conversations but no filter UI in queue.

## Recent Commits (Last 10)

- 13625cf - Merge PR #18: qa/batch1-security-and-validation-fixes
- 6ad5acd - Update doc version to reflect design progress
- 0314269 - fix: format projects_live.ex for mix format --check-formatted
- e56dfc7 - Fix Credo strict findings: reduce complexity and nesting depth
- a729755 - Fix Sobelow CSRF finding: remove GET /logout route
- 57de4e0 - Fix portal path generation to always use token-based routes
- 3399394 - fix: format files for mix format --check-formatted
- d492577 - Security and validation fixes across codebase
- fde7c47 - Remove redundant Erlang options
- a87c46e - Refactor form field updates to use render_change
