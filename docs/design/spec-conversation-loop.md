# Prospect Conversation Loop

**Version:** 0.4 — Supplements SDD v0.4; supersedes SDD §5.2 MVP outbound behavior
**Date:** 2026-07-05

**Revision note:** The five open questions from the prior draft are resolved with the best-guess decisions recorded in [Resolved Decisions](#resolved-decisions), pending ratification. Their consequences are folded into the requirements below.

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
- Each organization has a configured reply-from address; an outbound reply uses its conversation's organization reply-from address as the From identity.
- A reply-from address is valid only if it corresponds to a verified sending domain registered with the email service.

### Sender Verification

- Setting or changing an organization's reply-from address validates it against the email service's verified sending domains; an unverified address is rejected at configuration time.
- An outbound reply whose reply-from address is unverified is not dispatched. The message is recorded with delivery status `failed` and surfaced to the operator. Delivery failure is never silent.

### Delivery Tracking

- Every outbound message records the external message identifier returned by the email service, and a delivery status.
- Delivery status values: pending, sent, delivered, bounced, suppressed, failed.
- A dedicated status webhook endpoint — separate from the inbound-message pipeline — receives delivery lifecycle events and updates the corresponding message, correlated by external message identifier.
- Status events are authenticated with the same signature scheme as inbound webhooks.
- Delivery statuses are ranked: pending precedes sent precedes delivered; bounced, suppressed, and failed are terminal. An incoming status event updates a message only if its rank exceeds the current status or it is a terminal state. Lower-ranked, equal, or duplicate events are ignored, so out-of-order event delivery does not regress a message's status.
- Each outbound message in the conversation thread displays a delivery indicator; bounce and suppression states are visually distinct.

### Bounce and Suppression Handling

- A bounce or suppression event sets the associated contact's email-validity status (valid, bounced, suppressed).
- A contact with a bounced or suppressed email-validity status is visibly flagged in the operator interface.
- A bounce or suppression on an outbound reply raises operator attention through notification, the attention queue, or both.
- An email-validity flag does not automatically block future sends to the contact; dispatch remains at operator discretion.

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
- Automatic contact-validity management from bounce events (see Resolved Decisions).
- Attachment handling on outbound replies.
- Conversation merging.

## Dependencies

- Transactional email service providing per-organization inbound routes, an outbound sending interface, and delivery-status webhook callbacks (Lettermint).
- Existing conversation state machine, attention scoring engine, and portal surfaces (SDD §4–§6).

## Constraints

- Single self-hosted application; operator and portal surfaces are route partitions, not separate services.
- The email service integration remains replaceable; LMTP and IMAP ingestion paths against operator-controlled mail infrastructure continue to function.

## Data Model Impact

- Delivery status is a mutable attribute of the outbound message record, not a separate entity. Message body and threading metadata remain fixed after insertion; only the status field advances.
- Each delivery-status transition produces an append-only activity-log entry, preserving an immutable history of the delivery lifecycle without duplicating message content.
- The organization record holds the reply-from address.
- The contact record holds an email-validity status (valid, bounced, suppressed).
- The delivery-status value set is `pending, sent, delivered, bounced, suppressed, failed`.

## Acceptance Criteria

- A message delivered to an organization's route URL appears in the attention queue as a conversation linked to that organization and, when the sender is resolvable, to the correct contact.
- Redelivering the same inbound message produces no additional conversation or message records.
- A webhook request with an invalid signature or stale timestamp is rejected with no side effects.
- An operator reply arrives in the customer's mailbox threaded under the original message in standard mail clients.
- After the email service reports delivery lifecycle events, the message record reflects the corresponding status, and the conversation thread displays it.
- A bounced reply is visually distinguishable in the conversation thread.
- A contact with portal access sees the operator's reply in the portal thread without email access.
- An operator without the admin role cannot create, modify, or delete routes or settings.
- Setting an organization reply-from address that is not a verified sending domain is rejected at configuration time.
- Attempting to send a reply from an unverified address produces a message with status `failed`, visible to the operator, and no silently dropped mail.
- A status event ranked at or below a message's current status leaves the status unchanged; a delivered event received before a sent event still results in delivered status.
- A bounce event marks the recipient contact as bounced and flags the contact in the operator interface.

## Rejected Alternatives

- CC/BCC capture of replies sent from the operator's personal mail client: portal-visible latency makes operator responses invisible to portal-active customers.
- Extending the inbound dispatcher to carry status events: the dispatcher is coupled to inbound-message shape; a dedicated endpoint is cleaner.
- Global uniqueness on contact email: per-organization composite uniqueness supports multi-organization contacts resolved via route context.
- Reply-from address on the inbound route: one sending identity per organization matches the single-relationship model; route-level override is unnecessary until per-project routes exist.
- Strict monotonic status transitions rejecting any regression: out-of-order webhook delivery would drop legitimate later events; rank-with-terminal-wins tolerates reordering.
- Separate delivery-receipts table for status: message body is fixed while only status advances, so a mutable status column plus the activity log is sufficient.
- Automatic send-blocking on a bounced contact: preserves operator discretion in the white-glove relationship; the flag informs rather than gates.

## Resolved Decisions

Best-guess resolutions of the prior open questions, recorded 2026-07-05, pending ratification.

| Question                                | Decision                                                                                  | Load-bearing reason                                                                     |
| --------------------------------------- | ----------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------- |
| Where the reply-from identity lives     | On the organization record                                                                | Routing context is org-scoped; one relationship, one sending address                    |
| Verified-sender validation point        | Configuration time (reject unverified) and send time (fail closed)                        | Prevents silent SMTP rejection at both the earliest and last opportunity                |
| Delivery-status transition ordering     | Rank-based; higher rank or terminal state wins, lower or equal ignored                    | Tolerates out-of-order status webhooks without regressing state                         |
| Bounce or suppression effect on contact | Sets a contact email-validity flag; surfaces and notifies; does not auto-block sends      | Bounces are operationally critical to see, but send decisions stay with the operator    |
| Message immutability vs. mutable status | Mutable status column on the message; activity log holds the immutable transition history | Body stays fixed; status is inherently lifecycle state; append-only log preserves audit |

## Deferred Work

- ~~SDD v0.4 revision: align §5.2 (outbound) and §7 (activation flow, definition of done) with routed-webhook-first intake and platform-native outbound.~~ Done — SDD is now v0.4; §3.3 and §4.1 adjusted to match.
- Per-contact portal authentication with admin/member visibility scoping: direction agreed (SDD US-7), separate effort.
- Per-project routes and disambiguation flow: designed in the Design Decisions document, awaiting the project entity's v2 scope.
