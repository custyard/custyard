# Public Intake and Slug Claim

**Version:** 0.1 — Supplements SDD v0.4 and the Prospect Conversation Loop spec
**Date:** 2026-07-05

## Summary

The path from a pricing-page call-to-action ("Join the Waitlist," "Contact Us for a quote") to a tracked conversation in the attention queue. A prospect who clicks a CTA lands on a sparse, branded intake page, starts a conversation without authenticating, and anchors it by claiming an organization slug together with a contact email. This closes the gap between the platform's stated goal — first contact from a pricing-page CTA becomes an identified conversation — and the two existing intake modes (routed email, authenticated portal), neither of which accepts an anonymous web request.

## Intake Modes

This feature adds a third intake mode. The three modes differ in where identity comes from:

| Mode | Identity source | Conversation created |
|------|----------------|----------------------|
| Routed email | The channel (route token in the callback URL) | After sender resolution |
| Portal | The authenticated session | Attributed at creation; never anonymous |
| Public intake (this spec) | Captured after creation (email + slug claim) | Anonymous at creation |

The existing rule "portal-sourced conversations are never anonymous" is unchanged; public-intake conversations carry their own source value and are not portal-sourced.

## Goals

- A prospect moves from CTA click to a submitted conversation without creating an account, authenticating, or completing mandatory fields beyond the message itself.
- Every public-intake conversation appears in the attention queue with its CTA context (waitlist, quote) attached.
- The prospect leaves the flow with a durable way to return to the conversation and a reply channel the operator can use.
- Identity capture is framed as value acquisition — claiming the organization's slug — rather than a contact-information demand.
- The claimed slug is the same slug the organization uses if the relationship converts; there is one namespace and no later reconciliation.

## Non-Goals

- Hosting or generating the pricing page or its CTAs; the platform receives interest, it does not generate it.
- Qualifying, scoring, or filtering prospects at intake. Intake is a net, not a filter; rejection cost is paid on the dismiss side.
- Preventing all fraudulent or frivolous slug claims. Claims are cheap to expire and cheap for the operator to release.
- Account creation or portal authentication during intake. Portal access arrives later in the relationship.

## Functional Requirements

### Intake Page

- Each CTA links to a public intake page identified by an intake source key (e.g., waitlist, quote); the key determines the conversation's initial tags and copy variant.
- The intake page presents one required field: the prospect's message. Submitting it creates a conversation.
- The page carries the operator's branding and no platform branding beyond what the operator chooses to show.
- Submission requires no authentication and no fields beyond the message.

### Conversation Creation

- Submission creates a conversation with source `public_intake`, no organization, and no contact. The message becomes the first message; a title is derived from the message when no subject exists.
- The intake source key is recorded on the conversation and rendered as tags visible in the attention queue.
- Public-intake conversations enter the attention queue on creation, scored with the same engine as all other conversations. Unmatched/unlinked weighting applies until an organization link exists.
- A conversation without a captured email is visibly flagged in the operator interface as having no reply channel. It is never silently hidden from the queue.

### Resume Access

- Conversation creation issues a claim token bound to the conversation. The token is returned in the resume URL and set as a browser cookie.
- The resume URL grants read and reply access to that conversation only. Possession of a conversation identifier or slug alone grants nothing.
- A prospect returning via the resume URL sees the thread, including operator replies, and can reply.

### Slug Claim

- After submission, the flow offers the prospect a slug claim: reserving a name in the organization-slug namespace, presented together with the email field that anchors it ("where do we confirm the claim").
- Claiming requires an email address. The claim is provisional at submission and confirmed when the prospect follows a confirmation link delivered to that email.
- The slug is a label, not a key. Visiting a claimed slug's address does not expose the conversation; access still requires the claim token or a confirmed-email link.
- Slug format follows the existing portal-slug rules (lowercase, hyphenated, DNS-label safe). A reserved-word list excludes platform and infrastructure names (e.g., `www`, `mail`, `api`, `portal`, `admin`).
- Claimed and provisioned slugs share one namespace with the organization portal slug. A slug's lifecycle is: `available → claimed (provisional) → confirmed → provisioned` (attached to an organization). No two live claims or organizations hold the same slug.
- An unconfirmed claim expires after a configurable period (default 72 hours, matching the disambiguation TTL precedent) and the slug returns to available. Expiry releases the slug only; the conversation persists.
- The operator can release any claimed or confirmed slug from the operator interface.

### Email Capture and Resolution

- Capturing an email (via slug claim or the standalone prompt for prospects who decline the claim) triggers sender resolution using the existing priority: contact match, organization domain match, otherwise a new prospect identity.
- A resolved match links the conversation to the existing contact and organization. No match creates nothing automatically beyond recording the email on the conversation; contact and organization creation remain operator actions or conversion outcomes.
- Once an email is captured, operator replies to the conversation are delivered to it through the platform-native outbound path (threading, delivery tracking, and failure semantics per the Prospect Conversation Loop spec).
- The no-reply-channel flag clears when an email is captured.

### Conversion

- When the operator converts a prospect (creates the organization), a confirmed slug claim held by that prospect's conversation promotes to the organization's portal slug in the same operation.
- Conversion links the conversation to the new organization; the conversation's history is preserved unbroken across the transition.

## Non-Functional Requirements

- **Security:** Claim tokens are high-entropy (at least 256 bits) and unique. The intake endpoint, resume endpoint, and claim-confirmation endpoint are rate-limited. Confirmation links are single-use and expire with the claim.
- **Abuse resistance:** Slug claims are bounded per source address per time window. Malformed or oversized submissions produce a structured error, not a server error. User-supplied values never expand unbounded runtime state.
- **Input handling:** Prospect-submitted content is treated as hostile input under the same sanitization rules as inbound email.
- **Privacy:** The resume URL and confirmation link are the only artifacts that grant access; neither is guessable from the slug or any public value.

## In Scope

- Public intake pages keyed by CTA source, with operator branding.
- Anonymous conversation creation with source `public_intake` and CTA tags.
- Claim-token resume access (URL + cookie).
- Slug claim with email anchor, confirmation link, expiry, and operator release.
- Single slug namespace shared with organization portal slugs, with claim → provisioned promotion at conversion.
- Sender resolution on email capture; reply-channel flagging.
- Prospect-visible thread and reply via the resume URL.

## Out of Scope

- Per-conversation subdomains (`abcd1234.acme.example.com`): conversations are addressed by path under the claimed slug or resume URL. (See Rejected Alternatives.)
- Portal account provisioning during intake; portal authentication follows the existing portal spec.
- CAPTCHA or proof-of-work challenges (revisit if abuse is observed; rate limiting is the first line).
- Custom fields, attachments, or urgency selection on the intake form.
- Notification emails to the prospect beyond the claim confirmation and operator replies.
- Embedding the intake form in the operator's site (iframe/JS widget); intake is a hosted page.

## Dependencies

- Platform-native outbound email with delivery tracking (Prospect Conversation Loop spec) — operator replies to captured emails travel this path.
- Existing sender-resolution priority and attention-scoring engine (SDD §4–§5).
- Organization portal slug and custom-domain machinery (SDD US-8) — the shared namespace this feature claims into.

## Constraints

- Wildcard TLS covers one label (`*.example.com`); per-conversation subdomains would require per-organization wildcard certificates. Conversation addressing is therefore path-based.
- Single self-hosted application; the intake surface is a route partition, not a separate service.

## Acceptance Criteria

- Submitting a message on an intake page creates a conversation visible in the attention queue with the CTA source tag, with no authentication and no other fields completed.
- The submission response includes a resume URL; visiting it from a fresh browser session shows the conversation thread and accepts a reply.
- Visiting a claimed slug's address without the claim token or a confirmed-email link exposes no conversation content.
- Claiming a slug with an email delivers a confirmation link; following it marks the claim confirmed. The same slug cannot be claimed by a second party while the first claim is live.
- An unconfirmed claim past its expiry releases the slug; the conversation and its messages remain intact.
- Capturing an email that matches an existing contact links the conversation to that contact and organization.
- A conversation with no captured email displays a no-reply-channel flag; capturing an email clears it.
- After the operator converts the prospect to an organization, the confirmed slug serves as that organization's portal slug and the original conversation appears in the organization's history.
- A burst of submissions from one address beyond the rate limit receives structured rejections and creates no further conversations.

## Rejected Alternatives

- CTA form submits via email to a catchall address: loses CTA context, adds mail latency, and cannot offer the slug claim or resume access.
- Per-conversation subdomains (`abcd1234.acme.example.com`): two-level wildcards are not issuable from a single public wildcard certificate; path-based routing preserves the addressing without per-organization certificate provisioning.
- Slug URL as the access credential: memorable names are enumerable; a label must not be a key.
- Email required before conversation creation: raises intake friction and contradicts the open-intake principle; anonymous-first with identity-after preserves the net-not-filter posture.
- Separate prospect-slug and organization-slug namespaces: collision between a claimed name and a later organization slug forces manual reconciliation; one namespace with lifecycle states removes the class of conflict.
- Auto-creating a contact/organization on email capture: unconverted prospects would litter the relationship data; resolution links to existing records, creation stays an operator decision.

## Resolved Decisions

Recorded 2026-07-05, pending ratification.

| Question | Decision | Load-bearing reason |
|----------|----------|---------------------|
| Where identity capture happens | After conversation creation, anchored to the slug claim | Zero-friction intake; the claim reframes capture as acquisition |
| What holds the claim | The email confirmation, not the slug or browser state | The slug is a label; the email is the only durable, operator-usable anchor |
| Slug namespace | One namespace shared with organization portal slugs, lifecycle `claimed → confirmed → provisioned` | Eliminates claim/organization collision and later reconciliation |
| Conversation addressing | Path-based under a single wildcard domain | Public CAs do not issue two-level wildcards; per-org certificates are avoidable cost |
| No-email conversations | Kept in the queue, flagged; only the slug reservation expires | Open intake — the message may be valuable even when unreachable |
| Claim expiry | Configurable, default 72 hours | Matches the disambiguation TTL precedent |

## Open Questions

- Claim-offer copy and weight per CTA: whether the quote path presents the full slug claim or a lighter email prompt is a conversion question; closing it requires operator judgment or live comparison.
- Prospect notification on operator reply: whether a reply to a resumed-but-unclaimed conversation (email captured, no slug) sends a notification email or relies on the prospect returning; interacts with the portal-notification open question in SDD Appendix A.

## Deferred Work

- Intake-form theming beyond the operator's global branding (per-CTA visual variants): direction is operator-configured variants; not needed for the first loop.
- Slug claim surfaced during portal onboarding for email-originated prospects: same namespace and lifecycle apply; entry point is separate work.
