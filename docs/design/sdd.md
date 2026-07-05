# Software Design Document: Relationship-Driven Service Platform (aka Customer onboarding platform)

**Working title:** TBD (referred to as "the platform" throughout)
**Version:** 0.4 — MVP specification
**Date:** 2026-07-05

**Revision note (v0.4):** §5.2 (outbound) and §7 (activation flow, definition of done) are reconciled with routed-webhook-first intake and platform-native outbound, as specified in the [Prospect Conversation Loop](spec-conversation-loop.md). Supporting edits in §3.3 and §4.1 keep this document internally consistent. The deeper architecture and data-model reconciliation — inbound-route entities, multi-webhook fan-out, per-project routes and the disambiguation flow — remains recorded in [design-decisions-email-routing.md](design-decisions-email-routing.md) and is not folded into §3–§4 here.

---

## 1. Problem Statement

High-touch SaaS service delivery generates a continuous stream of heterogeneous requests tied to specific customer relationships. These requests vary in type (questions, investigations, configuration changes, incident response), urgency, and effort. They arrive primarily via email, embedded in ongoing conversations with known contacts at known organizations.

The operator excels at lateral thinking — investigating, connecting dots, solving novel problems — but has difficulty with the linear execution required to maintain a queue: processing the oldest item, updating statuses, scanning backlogs. Existing tools force the operator to be the sequencer. The platform must be the sequencer instead.

Three categories of existing tools were evaluated and found insufficient:

**PSA tools** (HaloPSA, Odoo) handle the full lifecycle but assume the human maintains the queue. Their surfacing mechanisms (SLA timers, dashboards) help but still require diligent status updates to function correctly.

**Customer onboarding platforms** (Rocketlane, GuideCX) provide excellent client-facing portals but model onboarding as a finite project with a completion milestone. They don't handle the indefinite ongoing service relationship.

**Ticketing systems** (Zammad, Jira Service Management) are ticket-centric rather than relationship-centric. The primary object is the work item, not the customer. Relationship context requires clicking through hierarchies rather than being ambient.

### What the platform must do differently

1. Make the **relationship** the primary object. Every interaction, question, task, and project exists subordinate to a customer context.
2. **Capture with near-zero friction.** Email-in via Sieve pre-routing. No mandatory fields on intake. A message becomes a conversation becomes a task only when that transition is warranted.
3. **Surface what needs attention without operator-driven sequencing.** Aging signals, relationship-weighted priority, and neglect detection replace manual backlog scanning.
4. **No hard lifecycle boundary.** A customer's first implementation project and their request two years later live in the same relationship context. Onboarding is a phase, not a separate system.
5. **Client portal as a first-class surface.** Customers log in, see what's pending, file requests, and track progress without scheduling a meeting or sending an email.
6. **Self-hosted with data sovereignty.** The operator controls where data lives. No dependency on US-based SaaS infrastructure for customer data.

---

## 2. Core User Stories and Acceptance Criteria

### Actors

- **Operator**: The service provider (you). Investigates, responds, configures, deploys. One person or a small team.
- **Customer contact**: A person at a customer organization. Files requests, asks questions, tracks progress.
- **Customer admin**: A customer contact with elevated visibility (sees all activity for their organization, not just their own).

### 2.1 Email Capture

**US-1: Inbound email creates a conversation**
As an operator, when a customer sends an email to a monitored address (or when Sieve forwards an email from a known customer domain), the platform creates a Conversation record linked to the matching Organization and Contact.

Acceptance criteria:
- Sender address is matched against known Contacts. If matched, Conversation is linked to that Contact and their Organization.
- If sender is unknown but domain matches a known Organization, Conversation is linked to the Organization with a flag for contact creation.
- If sender is entirely unknown, Conversation is created in an "unmatched" queue.
- Email subject becomes the Conversation title. Body becomes the first message. Attachments are stored and linked.
- Reply threading uses In-Reply-To/References headers to append to existing Conversations. Subject-line fallback matching (configurable) handles new-thread replies.
- No mandatory fields beyond what the email itself provides. No classification, no priority, no category required at intake.

**US-2: Sieve pre-routing injects metadata**
As an operator, I can configure Sieve rules that add custom headers (e.g., `X-Customer-Tier`, `X-Route-Queue`) to forwarded messages, and the platform reads these headers to set initial properties on the Conversation.

Acceptance criteria:
- Platform reads a configurable list of custom headers on inbound messages.
- Header values map to platform properties (Organization tier, initial queue, priority hint) via a configuration table.
- Sieve routing is purely additive — the platform functions correctly with no custom headers, using only sender-based matching.

### 2.2 Conversation Lifecycle

**US-3: Conversations have a lightweight state model**
As an operator, a Conversation moves through states that reflect its actual status without requiring me to manually advance it through a workflow.

States:
- **New**: Just arrived. No operator interaction yet.
- **Active**: Operator has viewed or responded. Work is in progress or a response has been sent.
- **Waiting**: Blocked on the customer (awaiting information, approval, access).
- **Dormant**: No activity from either side for a configurable period. Automatically set.
- **Resolved**: Operator has marked the conversation as complete.

Acceptance criteria:
- Transition from New → Active happens automatically when the operator views or responds.
- Transition to Waiting is operator-initiated (explicit "waiting on customer" action).
- Transition to Dormant is automatic based on inactivity threshold (configurable per Organization tier).
- Any inbound message on a Dormant or Resolved conversation transitions it back to Active.
- No other states exist. No "in progress," "under review," "escalated" substates in the MVP. Tags handle categorization.

**US-4: Conversations can spawn Tasks**
As an operator, when a conversation reveals concrete work to be done, I can create one or more Tasks linked to that Conversation.

Acceptance criteria:
- Tasks have: title, description (optional), due date (optional), effort estimate (optional).
- A Conversation can have zero or many Tasks.
- Tasks have their own state: Open, In Progress, Done.
- Task completion does not automatically resolve the parent Conversation (the operator may need to communicate the result).
- Tasks are visible on the Organization's relationship view and in the client portal (if portal-visible flag is set).

### 2.3 Automatic Surfacing (The Linear Thinker)

**US-5: The attention queue surfaces what needs action**
As an operator, I see a single prioritized view ("attention queue") of Conversations and Tasks that need action, ordered by a composite score.

Scoring inputs (each configurable in weight):
- **Age since last operator action**: How long since the operator touched this item.
- **Organization tier**: Higher-tier customers surface faster.
- **State**: New items score higher than Active items. Waiting items score lower (customer's turn). Dormant items that have re-activated score highest (something woke up).
- **Explicit urgency signals**: Keywords in subject/body (configurable: "down," "outage," "urgent," "security"), or customer-set urgency via portal.
- **Conversation velocity**: A conversation with 5 messages in the last hour scores higher than one with 1 message last week.

Acceptance criteria:
- The attention queue is the default view on login. It is not a dashboard to be navigated to; it is the landing page.
- Each item in the queue shows: Organization name, Contact name, Conversation title, time since last operator action, current state, and tags.
- The queue updates in real-time (or near-real-time via polling/SSE).
- The operator can dismiss an item from the queue (snooze for N hours/days) without changing its state.
- The scoring algorithm is transparent: the operator can see why an item is ranked where it is.

**US-6: Neglect alerts fire when items age past thresholds**
As an operator, I receive notifications when Conversations exceed configurable age thresholds without operator action.

Acceptance criteria:
- Thresholds are configurable per Organization tier (e.g., Enterprise: 4 hours, Standard: 24 hours).
- Notifications are delivered via the platform's own notification system and optionally via email.
- Neglect alerts appear as a distinct signal in the attention queue (not just higher score, but a visual indicator).
- A "neglect report" view shows all items currently past their threshold, grouped by Organization.

### 2.4 Client Portal

**US-7: Customer contacts can view and interact through a portal**
As a customer contact, I can log in to a web portal scoped to my Organization and see:
- All Conversations I've filed (or all Conversations for my Organization, if I'm an admin).
- Current state and last activity on each Conversation.
- Tasks linked to my Conversations (those flagged as portal-visible).
- The ability to file a new request (which creates a Conversation).
- The ability to reply to an existing Conversation (which appends a message and transitions state if Dormant/Resolved).

Acceptance criteria:
- Authentication is handled via Rodauth (email/password + optional SSO via rodauth-omniauth for customers who want it).
- Portal is scoped: a customer contact sees only their Organization's data. No cross-organization visibility.
- Filing a new request through the portal has the same minimal-friction principle as email: title and description, nothing mandatory beyond that.
- Portal responses are threaded into the same Conversation the operator sees. No separate "portal messages" vs "email messages" distinction.
- Conversations are displayed newest-first by default, with filters for state.

**US-8: Portal is white-label capable**
As an operator, I can configure the portal's branding (logo, colors, domain) per Organization or globally.

Acceptance criteria:
- Custom domain support via CNAME (the operator's existing DNS/TLS infrastructure handles termination).
- Logo and primary color are configurable globally and overridable per Organization.
- The platform's own branding does not appear on the portal unless the operator chooses to show it.

### 2.5 Relationship Context

**US-9: The Organization view is the primary navigation surface**
As an operator, I can view an Organization page that shows:
- All Conversations (grouped by state) for that Organization.
- All Contacts at that Organization.
- Organization metadata (tier, domain, notes, custom fields).
- A timeline of all activity (messages, state changes, task completions) in reverse chronological order.
- Any active onboarding or implementation Projects.

Acceptance criteria:
- The Organization view is reachable in one click from any Conversation belonging to that Organization.
- The timeline is unified across all Conversations and Tasks, not siloed per Conversation.
- Search within an Organization scopes to that Organization's Conversations, Tasks, and notes.

### 2.6 Projects (Onboarding and Beyond)

**US-10: Projects group related Tasks with optional templates**
As an operator, I can create a Project linked to an Organization. A Project is a container for related Tasks, optionally initialized from a template.

Acceptance criteria:
- A Project has: title, description, start date, target completion date, and a list of Tasks.
- Templates define a set of Tasks with relative due dates (e.g., "Day 1: Collect DNS records," "Day 3: Configure SSO," "Day 7: Admin training").
- Instantiating a template calculates absolute dates from the Project start date.
- Projects are visible in the client portal (with per-Task visibility flags).
- A Project can be linked to a Conversation (e.g., the initial onboarding request), but Projects also exist independently.
- There is no "project completion" state that triggers a lifecycle transition. The Project is simply a grouping mechanism. Tasks within it complete individually.

### 2.7 Secondary Workflow: Internal Project Tracking

**US-11: Internal projects track open-source tools and experiments**
As an operator, I can create Projects not linked to any Organization, for tracking internal work (open-source libraries, web tools, experiments).

Acceptance criteria:
- Internal Projects have the same Task model as customer Projects.
- Internal Projects appear in the attention queue based on Task due dates and aging, using the same scoring mechanism (but without Organization tier weighting).
- Internal Projects are never visible in the client portal.
- Tags distinguish internal projects by type (e.g., "oss-library," "experiment," "web-tool").

---

## 3. Technical Architecture

### 3.1 Stack Tradeoffs

TBD

### 3.2 System Topology

```
┌─────────────────────────────────────────────────────────────┐
│                    Edge / TLS Termination                    │
│           (static assets, routing, rate limiting)            │
├───────────────┬─────────────────────┬───────────────────────┤
│               │                     │                       │
│  Operator UI       Client Portal              API           │
│            (single application, route-partitioned)          │
├─────────────────────────────────────────────────────────────┤
│                     Application Layer                        │
│  ┌──────────────┐ ┌────────────────┐ ┌────────────────────┐ │
│  │    Email     │ │   Attention    │ │  Authentication    │ │
│  │  Ingestion   │ │    Scoring     │ │  (operator and     │ │
│  │   Pipeline   │ │    Engine      │ │   portal users)    │ │
│  └──────────────┘ └────────────────┘ └────────────────────┘ │
├─────────────────────────────────────────────────────────────┤
│                   Background Processing                      │
│      (email parsing, score recalculation, notifications)     │
├───────────────┬─────────────────────────────────────────────┤
│               │                                             │
│  Relational Store                    Cache / Job Queue      │
│  (primary data)                   (scores, background work) │
└───────────────┴─────────────────────────────────────────────┘

         ┌────────────────┐
         │  Operator's    │
         │  Existing MTA  │
         │  (with Sieve)  │
         └───────┬────────┘
                 │ LMTP or forward
                 ▼
         Email Ingestion Pipeline
```

The operator UI and client portal are route partitions within the same application, not separate services. This keeps deployment simple and means the data layer is shared without an internal API intermediary. Authentication is handled separately for operator accounts and customer portal accounts, with distinct session management and credential policies.

The platform integrates with the operator's existing mail infrastructure rather than replacing it. Email arrives via the MTA; Sieve rules can inject metadata before forwarding to the platform.

### 3.3 Component Responsibilities

**Email Ingestion Pipeline**

Receives email via routed inbound webhooks (per-organization callback URLs from the transactional email service, carrying routing context in the channel), LMTP delivery, or IMAP polling (operator's choice based on existing mail infrastructure). Parses RFC 5322 messages, extracts headers for threading, matches senders to known contacts, and creates or appends to conversations. Runs as a background process to avoid blocking on mail parsing.

**Attention Scoring Engine**

Computes and caches composite priority scores for all active conversations. Runs periodically (1-5 minute interval) rather than on every state change, trading slight staleness for predictable load. Scores are cached both on the conversation record and in a fast-access cache layer for queue rendering.

**Authentication**

Two separate authentication contexts:
- Operator accounts: Full platform access. Credentials, sessions, and optional MFA.
- Portal accounts: Scoped to a single organization. Linked to a contact record. Optional SSO integration for customers who require it.

Both use the same underlying authentication library with different configurations.

**Background Processing**

Handles email parsing, score recalculation, dormancy detection, neglect threshold checks, and notification dispatch. Work is enqueued and processed asynchronously. The queue must survive application restarts (persistent job storage).

### 3.4 Security Boundaries

**Operator / Customer Isolation**

Operator and customer authentication trees are entirely separate. A portal session cannot access operator routes. An operator session can access all customer data (necessary for service delivery) but the UI clearly distinguishes operator-initiated actions from customer-initiated actions in the activity log.

**Cross-Organization Isolation**

Portal users see only their own organization's data. This is enforced at the query layer, not just the UI. Every customer-facing query includes organization scope as a mandatory predicate, derived from the authenticated session. The application never constructs a cross-organization query in portal context.

**Email as Untrusted Input**

Inbound email is treated as hostile. HTML bodies are sanitized before storage and display. Attachments are stored outside the web-accessible path with content-type validation. Email headers are logged for debugging but never executed or interpreted beyond threading logic.

**Data at Rest**

Customer data, attachments, and conversation content require encryption at rest. The specific mechanism depends on deployment environment (filesystem encryption, database-level encryption, or both). Attachment storage is encrypted independently of the database.

**Multi-Tenancy Model**

Single database with organization-scoped rows. Appropriate for the expected scale (tens of organizations, not thousands). If strict data isolation becomes a requirement (compliance, customer demand), the architecture supports migration to schema-per-organization or database-per-organization, but this is not the default.

---

## 4. Data Model

### 4.1 Core Entities

**Organization**

The billable/contractual entity. A company or team that the operator provides service to.

- Has a name and primary domain (used for email sender matching when a contact isn't recognized)
- Assigned a service tier (e.g., enterprise, standard, basic) that affects attention queue weighting and neglect thresholds
- Has a unique portal slug for URL routing (e.g., `/portal/acme-corp`)
- Stores branding configuration (logo, colors, custom domain) for portal white-labeling
- May have freeform notes and custom fields for relationship context

*Matching behavior:* When an inbound email arrives, the platform first tries to match the sender address to a known Contact. If no Contact matches but the sender's domain matches an Organization's domain, the conversation is linked to the Organization with a flag indicating the contact needs to be created. Domain matching is a fallback, not primary.

**Contact**

A person at a customer organization.

- Linked to exactly one Organization
- Has an email address (unique across all contacts), name, and freeform role description
- May have a portal account (nullable; not all contacts need portal access)
- Tracks whether this contact is a portal admin (can see all organization activity vs. only their own conversations)

**Conversation**

The central work item. A thread of communication about a topic, question, or request.

- Linked to an Organization (required) and a Contact (nullable; null if sender was unmatched)
- Has a title (initially from email subject or portal form) and a state
- States: New, Active, Waiting, Dormant, Resolved
- Tracks timestamps: state changed, last operator action, last activity (any activity)
- Has an urgency level (normal, elevated, urgent) set by keyword detection or explicit customer flag
- Tagged with freeform labels for categorization
- Records source (email, portal, manual creation)
- Stores email Message-ID for threading
- May be snoozed until a specified time
- Caches its computed attention score

*State transitions:* New → Active on first operator view or response. Any state → Waiting on explicit operator action. Active/Waiting → Dormant automatically after configurable inactivity. Any state → Active on new inbound message. Any state → Resolved on explicit operator action.

**Message**

A single communication within a Conversation.

- Linked to a Conversation
- Has an author (operator, contact, or system) and author identifier
- Stores body as both plain text and sanitized HTML
- Records source (email, portal, internal note)
- Preserves email headers for threading and debugging
- Internal notes are visible only to operators, not in the portal
- For outbound messages sent via the transactional email service: tracks delivery status (pending, sent, delivered, bounced, suppressed, failed) and external message ID for webhook correlation. The `failed` status records a reply that was never dispatched (e.g. an unverified reply-from address), surfaced to the operator so delivery failure is never silent

**Attachment**

A file attached to a Message.

- Linked to a Message
- Has filename, content type, size, and storage path
- Stored outside web root, encrypted at rest

**Task**

A concrete piece of work, optionally spawned from a Conversation.

- May be linked to a Conversation, a Project, or neither (standalone task)
- May be linked to an Organization (null for internal/non-customer tasks)
- Has title, optional description, optional due date, optional effort estimate
- States: Open, In Progress, Done
- Has a portal visibility flag (determines whether customers see it)
- Has a sort order for display within a Project

*Relationship to Conversations:* A Conversation can have zero or many Tasks. Task completion does not automatically resolve the parent Conversation; the operator may need to communicate the result.

**Project** *(v2)*

A container for related Tasks, used for onboarding, implementation, or other multi-step work.

- May be linked to an Organization (null for internal projects)
- Has title, description, start date, target completion date
- May be instantiated from a template
- Projects are visible in the portal (with individual task visibility controlled per-task)

**Project Template** *(v2)*

A reusable blueprint for Projects.

- Defines a set of task definitions with relative timing (e.g., "Day 1: Collect DNS records")
- When instantiated, relative days are converted to absolute dates from the project start date

**Activity Log**

An append-only record of all actions taken in the system.

- Linked to Organization, Conversation, Task, and/or Project as applicable
- Records actor (operator, contact, or system), action type, and action details
- Used for the Organization timeline view and audit purposes
- Never updated or deleted

**Neglect Threshold**

Configuration for when items are considered neglected.

- Defined per service tier
- Specifies warning threshold (e.g., 4 hours for enterprise, 24 hours for standard)
- Specifies critical threshold
- Thresholds trigger visual indicators in the attention queue and optional notifications

**Operator Account**

An account for someone who operates the platform.

- Email, name, credentials, MFA configuration
- In MVP, likely a single operator; model supports multiple

**Portal Account**

An account for a customer contact to access the portal.

- Linked to a Contact and an Organization
- Credentials managed separately from operator accounts
- Scoped entirely to the linked Organization

### 4.2 Entity Relationships

```
Organization (1) ←──────────────────── (many) Contact
      │                                         │
      │                                         │ portal account
      │                                         ▼
      │                                   Portal Account
      │
      ├──── (many) Conversation ────── (many) Message ────── (many) Attachment
      │            │
      │            └──── (many) Task
      │
      └──── (many) Project ────── (many) Task
                      │
                      └──── (from) Project Template

Activity Log references: Organization, Conversation, Task, Project (all optional)
```

### 4.3 Attention Score Computation

The attention score determines queue ordering. It is a weighted sum of the following factors:

**Idle Time**

Hours since the operator last acted on this conversation (or since creation if never touched). Uses a logarithmic scale to prevent runaway scores for ancient items while still distinguishing meaningful time differences. A conversation idle for 2 hours scores noticeably lower than one idle for 20 hours, but a conversation idle for 200 hours doesn't dominate the queue.

**State**

- New: High base score (untouched items need triage)
- Active: Moderate base score (work in progress)
- Waiting: Low or zero score (customer's turn; operator can't act)
- Dormant that has reactivated: Highest score (something woke up; likely needs attention)

**Organization Tier**

Higher-tier organizations surface faster. The weighting is configurable; a "standard" tier customer idle for 4 hours might score equivalently to an "enterprise" customer idle for 1 hour.

Unmatched senders (conversations not linked to a known organization) have their own configurable weight. This can be set high (ensure triage of potential new customers) or low (deprioritize likely spam).

**Urgency Signals**

Two sources of urgency:
- Keyword detection on intake (configurable list: "down," "outage," "urgent," "security," etc.)
- Explicit customer flag set via portal

Both add fixed bonuses to the score.

**Velocity**

Message count in the trailing 24 hours, logarithmically scaled. A conversation with 5 messages in the last hour surfaces faster than one with 1 message last week. Captures "active back-and-forth" that might need quick resolution.

**Neglect Penalty**

If the idle time exceeds the organization tier's warning threshold, a significant score boost is applied. If it exceeds the critical threshold, an even larger boost. This ensures neglected items surface near the top regardless of other factors.

**Snooze**

Snoozed items are excluded from the queue entirely (effectively negative infinity score) until the snooze expires. On expiration, the item returns to the queue with its normal calculated score.

**Transparency**

The scoring formula is not a black box. The operator can view a breakdown showing why any item is ranked where it is. All weights are configurable through the platform settings without code changes.

**Caching**

Scores are recomputed periodically (every 1-5 minutes via background job) rather than on every change. The computed score is cached on the conversation record and in a fast-access cache for queue rendering. This means the queue is eventually consistent, not real-time, but the delay is short enough to be imperceptible in practice.

### 4.4 Performance Considerations

**Attention Queue**

The attention queue query is the most frequent and latency-sensitive operation. It filters to actionable states (New, Active, and recently-reactivated Dormant), excludes snoozed items, and orders by cached score. This query must remain fast as conversation volume grows. Target: sub-100ms response at 10,000 conversations.

**Dormancy Detection**

A background process periodically scans for conversations that have exceeded the inactivity threshold and transitions them to Dormant. This runs less frequently than score computation (e.g., every 15-30 minutes) since dormancy is not time-critical.

**Full-Text Search**

Conversation titles and message bodies are searchable. At MVP scale (hundreds to low thousands of conversations), database-native full-text search is sufficient. If search response time degrades past 500ms or conversation volume exceeds ~10,000, a dedicated search index becomes worthwhile.

**Activity Timeline**

The Organization view includes a unified activity timeline across all conversations and tasks. This is an append-only log ordered by time. At high activity volumes, pagination and time-range filtering prevent unbounded query sizes.

---

## 5. Operations and Interfaces

### 5.1 Email Ingestion

Email enters the platform through one of two mechanisms, chosen based on the operator's existing mail infrastructure:

**LMTP Delivery**

The platform listens on a configurable port for LMTP delivery. The operator's MTA routes mail to this endpoint. Each delivered message is enqueued for background parsing. This approach provides immediate handoff but requires the MTA to be configured for LMTP relay.

**IMAP Polling**

A scheduled job polls configured mailbox(es) via IMAP, fetches unread messages, marks them as read, and enqueues for parsing. This approach works with any standard mailbox but introduces polling latency (configurable interval, typically 1-5 minutes).

**Parsing Pipeline**

Regardless of ingestion method, each message goes through:

1. Parse headers (sender, subject, Message-ID, In-Reply-To, References)
2. Extract body (prefer text/plain; fall back to sanitized text/html)
3. Extract and store attachments
4. Read custom headers injected by Sieve (X-Customer-Tier, X-Route-Queue, etc.)
5. Match sender to Contact; fall back to domain match to Organization; fall back to unmatched queue
6. Thread matching: check In-Reply-To/References against existing conversations
7. Create new Conversation or append Message to existing one
8. Trigger score recalculation
9. Trigger notifications if applicable

**Sieve Integration**

The operator can configure Sieve rules on their MTA to inject custom headers before forwarding. The platform reads a configurable list of headers and maps values to conversation properties (initial tier, queue assignment, priority hints). This is purely additive; the platform functions correctly with no custom headers.

### 5.2 Outbound Communication

Outbound email is platform-native and in the MVP. The operator composes replies in the platform, and the platform sends them; the operator's personal mail client is not part of the loop. The full requirements, acceptance criteria, and resolved decisions live in the [Prospect Conversation Loop](spec-conversation-loop.md); this section states the behavior the SDD depends on.

**Composing and Sending**

When the operator composes a response in the conversation view:
- The platform sends it as email to the conversation's contact.
- Threading headers maintain continuity in the customer's mail client: In-Reply-To names the most recent customer message; References lists the thread's ancestors.
- Sending is asynchronous — composing does not block the operator interface.
- Sending transitions the conversation through validated state-machine transitions, not direct attribute writes.

**Sender Identity and Verification**

- Each organization has a configured reply-from address; an outbound reply uses its conversation's organization reply-from address as the From identity.
- A reply-from address is valid only if it corresponds to a verified sending domain registered with the email service. Setting or changing it is validated at configuration time, and an unverified address is rejected then.
- An outbound reply whose reply-from address is unverified is not dispatched. The message is recorded with delivery status `failed` and surfaced to the operator. Delivery failure is never silent — the platform fails closed at both the earliest (configuration) and last (send) opportunity.

**Delivery Status Tracking**

The platform receives webhook callbacks for email lifecycle events and records them against the originating Message, giving operators visibility into whether their replies reached the customer.
- A dedicated status webhook endpoint — separate from the inbound-message pipeline — receives delivery events and updates the corresponding message, correlated by external message identifier. Status events are authenticated with the same signature scheme as inbound webhooks.
- Delivery status values: pending, sent, delivered, bounced, suppressed, failed. Statuses are rank-ordered so out-of-order webhook delivery does not regress a message's status (see the conversation-loop spec for the ranking rule).
- Each outbound message in the thread shows a delivery indicator; bounce and suppression states are visually distinct. A bounce or suppression sets the contact's email-validity status and raises operator attention; it informs rather than gates future sends.

**Transport**

Outbound sending goes through the transactional email service (Lettermint) that also provides routed inbound intake and delivery-status callbacks. The integration remains replaceable; sending via SMTP relayed through the operator's existing MTA is a supported alternative, as LMTP and IMAP remain for intake.

### 5.3 Portal Operations

The client portal provides customer contacts with visibility into their service relationship and the ability to file and track requests.

**Authentication**

Portal accounts are separate from operator accounts. Authentication supports email/password with optional SSO integration for customers who require it. Each portal session is scoped to a single organization; there is no cross-organization access.

**Conversation Access**

- Non-admin contacts see only conversations they filed
- Admin contacts see all conversations for their organization
- All contacts can view current state, message history, and linked tasks (if portal-visible)
- All contacts can file new requests and reply to existing conversations

**Filing a Request**

The new request form has two fields: title and description. Nothing else is mandatory. Optional: urgency selector and file attachment. Submitted requests create a Conversation visible to both operator and customer, sourced as "portal" rather than "email."

**Replying**

Portal replies are threaded into the same Conversation the operator sees. There is no distinction between "portal messages" and "email messages" in the data model; only the source field differs. A reply to a Dormant or Resolved conversation transitions it back to Active.

**Project Visibility (v2)**

Projects linked to the organization are visible in the portal. Individual tasks within projects have a visibility flag; only portal-visible tasks are shown. Customers can see progress but cannot modify tasks.

**Branding (v2)**

The portal can be white-labeled per organization: custom domain (via CNAME), logo, and primary color. The platform's own branding does not appear unless the operator chooses to show it.

### 5.4 Operator Operations

**Attention Queue**

The landing page. Shows all conversations requiring action, ordered by attention score. Each item displays: organization name, contact name, conversation title, time since last operator action, current state, tags, and neglect indicator if applicable.

The operator can:
- Click an item to view it (transitions New → Active automatically)
- Snooze an item for a specified duration (removes from queue until expiration)
- Filter by state, organization, or tag

The queue updates in near-real-time (via polling or push, depending on implementation).

**Conversation Actions**

From a conversation, the operator can:
- Read the full message thread
- Add an internal note (not visible in portal)
- Change state to Waiting (blocked on customer) or Resolved
- Create one or more Tasks linked to this conversation
- View and navigate to the linked Organization
- See related conversations (other open items for this organization)

**Organization View**

Shows the full relationship context:
- Organization metadata (tier, domain, notes, custom fields)
- All conversations grouped by state
- Unified activity timeline across all conversations and tasks
- All contacts at this organization
- Active projects (v2)

**Neglect Report**

A dedicated view showing all items currently past their neglect threshold, grouped by organization. Useful for triage when the operator has been away or when volume spikes.

**Settings**

- Attention score weights (adjustable without code changes)
- Neglect thresholds per tier
- Email ingestion configuration
- Custom header mappings for Sieve integration
- Portal branding defaults

### 5.5 System Operations

**Notifications**

The platform sends notifications when:
- A neglect threshold is breached (warning or critical)
- A Dormant or Resolved conversation reactivates
- (v2) A task due date approaches or passes

Notifications are delivered through the platform's own notification system (visible in-app) and optionally via email to the operator.

**Dormancy Automation**

A background process transitions conversations from Active or Waiting to Dormant when inactivity exceeds the configured threshold. The threshold is per-organization-tier, not global.

**Recovery Behavior**

If the platform is down, email accumulates at the MTA (LMTP) or mailbox (IMAP). On recovery:
- LMTP: MTA retries delivery; messages arrive in a burst
- IMAP: Polling fetches accumulated messages

Both result in a batch of items entering the attention queue simultaneously. Many may breach neglect thresholds. The scoring algorithm handles this gracefully (neglect penalties stack, but log-scaled idle time prevents runaway scores), but the operator should expect a triage session after extended downtime.

---

## 6. UI/UX Specifications

### 6.1 Operator Interface

**Attention Queue (Landing Page)**

The attention queue is a single-column list of items requiring action. Each item is a card showing:

```
┌──────────────────────────────────────────────────────────┐
│ [●] Acme Corp                                    2h ago  │
│ Jane Smith · enterprise                                   │
│ "TLS security error — site appears down"                 │
│ ▓▓▓▓░░ urgency: urgent  state: new  │ 3 messages        │
│                                          [Snooze] [View] │
└──────────────────────────────────────────────────────────┘
┌──────────────────────────────────────────────────────────┐
│ [●] Widgets Inc                                  1d ago  │
│ Bob Chen · standard                                       │
│ "Can we lock down page A but leave page B public?"       │
│ ░░░░░░ urgency: normal  state: new  │ 1 message         │
│                                          [Snooze] [View] │
└──────────────────────────────────────────────────────────┘
```

- Items are ordered by attention score (highest first).
- Visual indicators for neglect (past-threshold items get a colored border: amber for warning, red for critical).
- Clicking an item opens the Conversation detail. This automatically transitions New → Active.
- Snooze opens a small popover: "Snooze for: 1h / 4h / 1d / 3d / custom."
- Filters (collapsed by default): by state, by organization, by tag.
- The queue can be bookmarked and refreshed. It's a stable URL, not a transient view.

**Conversation Detail**

A two-panel layout:

Left panel (wide): Message thread, newest at bottom. Inline reply box at the bottom. Each message shows author, timestamp, source icon (email/portal/internal note). Attachments are listed inline with download links.

Right panel (narrow): Conversation metadata (state, tags, urgency), linked Organization (clickable), linked Contact, linked Tasks (with quick-add), related Conversations (other open items for this Organization), and a state-change control.

**Organization View**

Header: Organization name, tier badge, domain, custom fields, edit button.
Below the header, tabbed or sectioned:
- **Activity timeline**: All activity across all Conversations and Tasks, reverse chronological. Unified, not per-Conversation.
- **Open Conversations**: Grouped by state (New, Active, Waiting, Dormant).
- **Projects**: Any active Projects with progress (tasks completed / total).
- **Contacts**: List of known contacts at this Organization with last-active dates.
- **Notes**: Freeform notes area for relationship context that doesn't belong in any specific Conversation.

### 6.2 Client Portal

The portal is visually distinct from the operator interface (customer branding, simpler navigation).

**Portal Home**

```
┌──────────────────────────────────────────────────────────┐
│  [Customer Logo]        My Requests    Projects    Help  │
├──────────────────────────────────────────────────────────┤
│                                                          │
│  Open Requests (3)                    [+ New Request]    │
│                                                          │
│  ┌────────────────────────────────────────────────────┐  │
│  │ TLS security error — site appears down             │  │
│  │ Filed 2 hours ago · Urgent · Active                │  │
│  │ Last update: "Looking into this now, checking..."  │  │
│  └────────────────────────────────────────────────────┘  │
│  ┌────────────────────────────────────────────────────┐  │
│  │ Lock down page A, leave page B public              │  │
│  │ Filed 1 day ago · Normal · Active                  │  │
│  │ Last update: "This is possible via..."             │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  Active Projects (1)                                     │
│  ┌────────────────────────────────────────────────────┐  │
│  │ SSO Configuration                                  │  │
│  │ Started Jan 15 · 4 of 7 tasks complete             │  │
│  │ Next: Configure SAML metadata (due Jan 22)         │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
└──────────────────────────────────────────────────────────┘
```

**New Request Form**

Two fields: Title and Description. Nothing else is mandatory. Optional: urgency selector (Normal / Elevated / Urgent) and file attachment. Submit creates a Conversation visible to both operator and customer.

**Conversation View (Portal)**

Same thread display as operator view, minus internal notes and operator-only metadata. Reply box at bottom. Attachments downloadable.

**Project View (Portal)**

Task list with completion status. Tasks marked `portal_visible = true` are shown. Each task shows title, state (Open / In Progress / Done), and due date if set. Customer cannot modify tasks but can see progress.

---

## 7. MVP Scope and Activation Flow

### 7.1 What's in the MVP

1. **Organizations and Contacts**: CRUD, domain-based matching, tier assignment, per-organization reply-from address.
2. **Email intake**: Routed inbound webhooks (per-organization callback URLs), with LMTP or IMAP as supported alternatives; sender matching, threading, conversation creation.
3. **Conversations**: Full lifecycle (New → Active → Waiting → Dormant → Resolved), message threading, and platform-native operator replies composed in the platform and sent as threaded email.
4. **Outbound and delivery tracking**: Platform-sent replies with In-Reply-To/References threading, verified reply-from (fail-closed on unverified), and per-message delivery status ingested from the email service's status webhook.
5. **Attention queue**: Composite scoring, real-time updates, snooze, neglect indicators.
6. **Neglect thresholds**: Configurable per tier, notification on breach.
7. **Client portal**: Authentication, conversation viewing and filing, reply threading.
8. **Tasks**: Create from conversations, basic state management, portal visibility toggle.
9. **Organization view**: Activity timeline, open conversations, contacts.

### 7.2 What's NOT in the MVP

- Projects and templates (v2 — add once the core conversation flow is validated).
- White-label portal branding (v2 — functional portal first, branding second).
- SSO for portal customers via rodauth-omniauth (v2 — email/password first).
- Internal project tracking / secondary workflow (v2).
- Per-project routes and the disambiguation DM flow (designed in the design-decisions document; the MVP loop uses per-organization routes only).
- Attachment handling on outbound replies.
- Reporting and analytics beyond the neglect report.
- Mobile-optimized portal (responsive layout handles basic cases; dedicated mobile optimization is post-MVP).

### 7.3 Activation Flow

The activation flow is the sequence from "platform deployed" to "first customer request flows through end-to-end." This is the MVP's entire proof of value.

```
Step 1: Deploy and configure
├── Platform deployed on operator's infrastructure (single server, Docker or systemd)
├── PostgreSQL and Redis running
├── Operator creates their account (first-run setup wizard)
├── Connect the transactional email service account (Lettermint)
├── Register the two webhook endpoints: routed inbound-message intake
│   and the separate delivery-status endpoint (both signature-verified)
├── (Alternative intake) Configure LMTP endpoint or IMAP credentials
│   against operator-controlled mail infrastructure
└── Verify intake with a test message on the configured path

Step 2: Seed relationship data
├── Create first Organization (name, domain, tier)
├── Provision its per-organization inbound route (unique callback URL)
├── Configure the Organization's reply-from address; verify it resolves
│   to a verified sending domain (unverified is rejected here)
├── Create Contacts for that Organization (email addresses)
└── Verify: send email to the Organization's route, confirm it creates
    a Conversation linked to the correct Organization and Contact

Step 3: Validate the attention queue
├── Let the test Conversation age past the neglect threshold
├── Verify: attention queue surfaces it with neglect indicator
├── Verify: score changes when organization tier is modified
└── Test snooze: snooze the conversation, verify it disappears,
    verify it reappears when snooze expires

Step 4: Test conversation lifecycle
├── View the Conversation (verify New → Active transition)
├── Set state to Waiting
├── Send another email from the customer (verify Waiting → Active)
├── Resolve the Conversation
├── Send another email from the customer (verify Resolved → Active)
└── Verify: all transitions appear in the Organization activity timeline

Step 5: Test platform-native reply and delivery tracking
├── Compose a reply in the conversation view; send it
├── Verify: it arrives in the customer's mailbox threaded under the
│   original message in a standard mail client (In-Reply-To/References)
├── Verify: the message's delivery status advances (pending → sent →
│   delivered) as status-webhook events arrive, shown in the thread
├── Verify: a customer reply returns to the Organization's inbound route
│   and appends to the same Conversation
└── Negative test: set an unverified reply-from and send; verify the
    message is recorded `failed`, surfaced to the operator, not silently dropped

Step 6: Enable the client portal
├── Create a portal account for a Contact at the test Organization
├── Log in as that Contact
├── Verify: only that Organization's Conversations are visible
├── File a new request via the portal
├── Verify: request appears in the operator's attention queue
├── Reply from the portal
├── Verify: reply appears in the operator's Conversation view
└── Verify: the operator's platform-sent reply appears in the portal thread

Step 7: Go live with one real customer
├── Create Organization + Contacts for a real customer
├── Provision the Organization's inbound route and verify its reply-from
├── Invite the customer contact to the portal
└── Monitor: first real request flows through capture → attention queue
    → operator reply (sent and delivery-tracked) → customer visibility in portal
```

### 7.4 Definition of Done for MVP

The MVP is done when:

1. An email from a known customer contact automatically creates a Conversation linked to the correct Organization and Contact, with no manual intervention.
2. The attention queue correctly surfaces Conversations ordered by the composite score, updates in near-real-time, and respects snooze.
3. Neglect thresholds fire and are visible in the attention queue for at least two distinct Organization tiers.
4. A customer contact can log into the portal, see their Conversations and current states, file a new request, and reply to an existing Conversation.
5. Portal-filed requests appear in the operator's attention queue indistinguishably from email-filed requests (the source is noted but the scoring and display are identical).
6. The full cycle works: customer contacts the Organization's route → platform captures → operator sees it in attention queue → operator replies from the platform → the reply arrives as a correctly threaded email → the customer sees the response in the portal.
7. Every outbound reply records a delivery status that advances from status-webhook events and is visible in the thread; an unverified reply-from address produces a `failed` message surfaced to the operator, with no silently dropped mail.
8. All of the above works on a single self-hosted server. The transactional email service (routed intake, outbound sending, delivery-status webhooks) is the one required external dependency for the platform-native loop, and it is replaceable; operator-controlled LMTP/IMAP intake and SMTP-relayed outbound through the operator's own MTA remain supported alternatives, preserving data sovereignty.

---

## Appendix A: Open Questions

1. **Outbound email timing** — *Resolved (v0.4).* Outbound email is load-bearing for the activation flow and is in the MVP: the operator replies from the platform and the platform sends the email, with delivery tracked. The prior CC/BCC-capture approach is a rejected alternative (portal-visible latency). See §5.2 and the [Prospect Conversation Loop](spec-conversation-loop.md).

2. **Multi-operator support**: The MVP assumes a single operator. When does multi-operator become necessary? The data model supports it (operator_accounts table, assignment fields could be added to conversations), but the attention queue scoring changes significantly with multiple operators (whose idle time? who is assigned?).

3. **Conversation merging**: Duplicate conversations from the same customer (new email thread about existing issue) are a known failure mode. The MVP handles this via In-Reply-To threading only. Manual merge (combine two Conversations into one) is a likely v1.1 requirement. How complex is the merge operation given the activity log architecture?

4. **Search scope**: PostgreSQL full-text search handles the MVP. At what volume does a dedicated search index (Meilisearch, Typesense — both self-hostable, non-US) become necessary? Estimated threshold: ~10k conversations or when search response time exceeds 500ms.

5. **Portal notification**: When the operator acts on a Conversation, should the customer contact receive an email notification? This creates a feedback loop (notification email might generate a reply that creates a new message on the Conversation). The design should handle this, but it needs explicit threading/loop-detection logic.

6. **Offline/degraded mode**: If the platform is down, email accumulates at the MTA (LMTP) or mailbox (IMAP). What's the recovery behavior? IMAP polling naturally handles this (poll on restart). LMTP requires the MTA to retry delivery. Both should work, but the "gap" period means the attention queue will show a burst of stale items on recovery, which may overwhelm the scoring if many items simultaneously breach neglect thresholds.
