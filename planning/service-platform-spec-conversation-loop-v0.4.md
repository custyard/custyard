# Prospect Conversation Loop

**Version:** 0.4 — Supplements SDD v0.3; supersedes SDD §5.2 MVP outbound behavior
**Date:** 2026-07-05

## Summary

The end-to-end path from a prospect's first inbound contact to a tracked, threaded operator reply visible in the customer portal. Covers routed intake, sender identity resolution, platform-native outbound email, delivery-status tracking, and portal visibility. This loop is the platform's proof of value.

## Goals

- A prospect's first contact — pricing-page call-to-action or email — becomes an identified conversation in the attention queue without operator intervention.
- Operator replies are composed in the platform and arrive in the customer's mail client as correctly threaded email.
- The delivery outcome of every outbound message is recorded and visible; delivery failure is never silent.
- Customers follow and continue the same conversation through the portal.

## Non-Goals

- Steady-state account management after onboarding (CRM territory).
- Hosting or generating marketing pages; the platform receives interest, it does not generate it.
- Multi-operator assignment or per-operator queues.
- Bulk or campaign email sending.

## Functional Requirements

### Intake

- Each organization has one or more inbound routes, each with a unique callback URL; the route token embedded in the URL identifies the route.
- Inbound webhook requests are verified by cryptographic signature and timestamp window before any processing.
- Inbound message processing is idempotent, keyed on the email message identifier; redelivery of the same message does not create duplicate records.
- A message arriving on an organization's route creates a conversation in that organization, or appends to an existing conversation matched by threading headers (In-Reply-To, then References).
- Sender resolution follows a fixed priority: route context, contact match within the route's organization, global contact match (catchall routes only), organization domain match, unmatched queue.
- Intake requires no fields beyond what the message itself provides.
- Requests filed through the portal are attributed to the authenticated contact; portal-sourced conversations are never anonymous.

### Operator Reply

- A reply composed in the conversation view is delivered as email to the conversation's contact.
- Outbound email carries threading headers: In-Reply-To names the most recent customer message; References lists all thread ancestors.
- Delivery is asynchronous; composing and sending does not block the operator interface.
- Sending a reply transitions the conversation state through validated state-machine transitions, not direct attribute writes.
- The reply From address is a sending identity configured for the organization.

### Delivery Tracking

- Every outbound message records the external message identifier returned by the email service, and a delivery status.
- Delivery status values: pending, sent, delivered, bounced, suppressed, failed.
- A dedicated status webhook endpoint — separate from the inbound-message pipeline — receives delivery lifecycle events and updates the corresponding message, correlated by external message identifier.
- Status events are authenticated with the same signature scheme as inbound webhooks.
- Each outbound message in the conversation thread displays a delivery indicator; bounce and suppression states are visually distinct.

### Portal

- A contact with portal access sees the full conversation thread, including operator replies and the conversation's current state.
- A portal reply appends to the same conversation the operator sees and reactivates a Dormant or Resolved conversation.

### Authorization

- Route and settings management is restricted to operators with the admin role.
- Operator access to a conversation is authorized; possession of a conversation identifier alone does not grant access.

## Non-Functional Requirements

- **Security:** Route callback tokens are high-entropy (at least 256 bits) and unique. Webhook endpoints are rate-limited.
- **Robustness:** Malformed, empty, or unexpected webhook payloads produce a structured error response, not a server error or process crash. User-supplied payload values never expand unbounded runtime state.
- **Consistency:** Message correlation lookups by external message identifier are indexed for constant-cost retrieval.
- **Observability:** The full delivery lifecycle of each outbound message is reconstructable from stored records.

## In Scope

- Routed webhook intake per organization.
- Sender identity resolution and conversation threading.
- Platform-composed outbound replies with email threading.
- Delivery-status ingestion and per-message indicators.
- Portal thread visibility and replies.
- Role-gated route and settings management.

## Out of Scope

- Per-project routes and the disambiguation DM flow (designed in the Design Decisions document; not required for this loop).
- Per-contact portal authentication accounts (portal access via organization token suffices for this loop).
- Automatic contact-validity management from bounce events (see Open Questions).
- Attachment handling on outbound replies.
- Conversation merging.

## Dependencies

- Transactional email service providing per-organization inbound routes, an outbound sending interface, and delivery-status webhook callbacks (Lettermint).
- Existing conversation state machine, attention scoring engine, and portal surfaces (SDD §4–§6).

## Constraints

- Single self-hosted application; operator and portal surfaces are route partitions, not separate services.
- The email service integration remains replaceable; LMTP and IMAP ingestion paths against operator-controlled mail infrastructure continue to function.

## Acceptance Criteria

- A message delivered to an organization's route URL appears in the attention queue as a conversation linked to that organization and, when the sender is resolvable, to the correct contact.
- Redelivering the same inbound message produces no additional conversation or message records.
- A webhook request with an invalid signature or stale timestamp is rejected with no side effects.
- An operator reply arrives in the customer's mailbox threaded under the original message in standard mail clients.
- After the email service reports delivery lifecycle events, the message record reflects the corresponding status, and the conversation thread displays it.
- A bounced reply is visually distinguishable in the conversation thread.
- A contact with portal access sees the operator's reply in the portal thread without email access.
- An operator without the admin role cannot create, modify, or delete routes or settings.

## Rejected Alternatives

- CC/BCC capture of replies sent from the operator's personal mail client: portal-visible latency makes operator responses invisible to portal-active customers.
- Extending the inbound dispatcher to carry status events: the dispatcher is coupled to inbound-message shape; a dedicated endpoint is cleaner.
- Global uniqueness on contact email: per-organization composite uniqueness supports multi-organization contacts resolved via route context.

## Open Questions

- **From-address modeling:** Neither the organization nor the inbound route stores the verified reply-from identity. Closing this requires a schema decision on where the sending identity lives.
- **Verified-sender validation:** Behavior when the configured From address is not a verified sending domain is unspecified; the failure mode is silent SMTP rejection. Closing this requires a validation point (configuration time, send time, or both).
- **Delivery-status transition ordering:** Whether regressive transitions (for example, sent → pending) are rejected is unspecified.
- **Bounce-driven contact flagging:** Whether and how bounce or suppression events change a contact's email-validity status is unspecified.
- **Message immutability:** Messages are immutable by design, while delivery status mutates over time. The resolution — mutable status column, separate delivery-receipts table, or event records — is unsettled.

## Deferred Work

- SDD v0.4 revision: align §5.2 (outbound) and §7 (activation flow, definition of done) with routed-webhook-first intake and platform-native outbound.
- Per-contact portal authentication with admin/member visibility scoping: direction agreed (SDD US-7), separate effort.
- Per-project routes and disambiguation flow: designed in the Design Decisions document, awaiting the project entity's v2 scope.
