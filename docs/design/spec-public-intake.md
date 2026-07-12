# Public Intake and Slug Claim

**Version:** 0.3 — Supplements SDD v0.4 and the Prospect Conversation Loop spec
**Date:** 2026-07-05

**Revision note:** v0.3 reconciles the spec with the codebase and the implementation design review (see [Design Decisions: Public Intake](design-decisions-public-intake.md)). Four premises in v0.2 referred to machinery that does not exist — portal-slug rules, unlinked scoring weight, a non-creating sender-resolution path, and a disambiguation-TTL implementation — and are restated as mechanisms this feature introduces. v0.3 also makes token handling, abuse bounds, retention, and addressing concrete.

## Summary

The path from a pricing-page call-to-action ("Join the Waitlist," "Contact Us for a quote") to a tracked conversation in the attention queue. A prospect who clicks a CTA lands on a sparse, branded intake page, starts a conversation without authenticating, and anchors it by claiming an organization slug together with a contact email. This closes the gap between the platform's stated goal — first contact from a pricing-page CTA becomes an identified conversation — and the two existing intake modes (routed email, authenticated portal), neither of which accepts an anonymous web request.

## Intake Modes

This feature adds a third intake mode. The three modes differ in where identity comes from:

| Mode | Identity source | Conversation created |
|------|----------------|----------------------|
| Routed email | The channel (route token in the callback URL) | After sender resolution |
| Portal | The authenticated session | Attributed at creation; never anonymous |
| Public intake (this spec) | Captured after creation (email + slug claim) | Anonymous at creation |

The existing rule "portal-sourced conversations are never anonymous" is unchanged; public-intake conversations carry their own source value (`public_intake`) and are not portal-sourced.

*Accuracy note:* portal conversations currently carry source `email`, not `portal` (the portal creation path omits the source); the never-anonymous invariant is enforced by the organization requirement, not the source value. Known divergence, tracked separately, outside this feature's scope.

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
- A general conversation-tagging system. The CTA source is a dedicated field rendered tag-style; open-ended tags are separate work.

## Functional Requirements

### Intake Page

- Each CTA links to a public intake page identified by an intake source key (e.g., waitlist, quote); the key determines the conversation's initial CTA context and copy variant.
- An intake page has one of two presentation modes, selected by the operator per intake source key:
  - **Active** — the full intake flow: message field, then the slug claim with its email anchor. Fits high-intent CTAs ("Join the Waitlist").
  - **Passive** — a lighter page that answers a short set of operator-configured prospect questions and offers the message form with an optional email field, linking to the active flow. Fits low-intent CTAs ("Learn more," "Contact us for a quote").
- In either mode, the message field is the only required field; submitting it creates a conversation. Viewing a passive page's informational content creates nothing.
- The page carries the operator's instance-level branding (name, logo, primary color — configuration introduced by this feature; all existing branding fields belong to customer organizations and cannot apply to an organization-less page) and no platform branding beyond what the operator chooses to show.
- Submission requires no authentication and no fields beyond the message.

### Conversation Creation

- Submission creates a conversation with source `public_intake`, no organization, and no contact. The message becomes the first message; the title is derived from the first line of the message, truncated to 80 characters (the intake form has no subject field).
- The intake source key is recorded in a dedicated field on the conversation (provenance survives configuration renames) and rendered as a tag-style badge in the attention queue.
- Public-intake conversations enter the attention queue on creation, scored by the same engine as all other conversations. This feature introduces the unlinked weighting: a configurable tier-equivalent score for conversations without an organization (default: the standard tier score), with neglect tracking on standard-tier thresholds. Previously, organization-less conversations scored zero and were exempt from neglect.
- Conversations without an organization are visible to and openable by all operator roles, including organization-scoped ones. They are never silently hidden from the queue.
- A conversation without a captured email is visibly flagged in the operator interface as having no reply channel. The flag is derived from the absence of a reply channel, never stored, so capturing an email clears it structurally.

### Resume Access

- Conversation creation issues a resume token bound to the conversation. The token is returned in the resume URL and set as a long-lived signed browser cookie (one year); the URL is the primary credential, the cookie a convenience for returning visitors.
- The resume URL grants read and reply access to that conversation only. Possession of a conversation identifier or slug alone grants nothing.
- A prospect returning via the resume URL sees the thread, including operator replies, and can reply.
- The operator can revoke or rotate a conversation's resume access.

### Slug Claim

- After submission, the flow offers the prospect a slug claim: reserving a name in the organization-slug namespace, presented together with the email field that anchors it ("where do we confirm the claim").
- Claiming requires an email address. The claim is provisional at submission and confirmed when the prospect follows a confirmation link delivered to that email. The link renders a confirmation page on GET and consumes the token only on an explicit confirm action, so mail-scanner prefetch cannot burn it.
- The slug is a label, not a key. Visiting a claimed slug's address does not expose the conversation; access still requires the resume token or a confirmed-email link.
- This feature creates the slug namespace; no slug machinery exists prior to it (portals are addressed by opaque token). Slug format: lowercase, DNS-label safe, 3–63 characters, hyphens interior-only, no `xn--` prefix. A reserved-word list, owned in code because it encodes routing facts, excludes platform route prefixes and infrastructure names (e.g., `www`, `mail`, `api`, `portal`, `admin`, `i`, `r`, `c`).
- Claimed and provisioned slugs live in one registry shared with organization portal slugs. A slug's lifecycle is: `available → claimed (provisional) → confirmed → provisioned` (attached to an organization). No two live claims or organizations hold the same slug. Slug-based portal routing remains separate work (SDD §4.1, organization portal slug) that consumes this registry.
- An unconfirmed claim expires after a configurable period (default 72 hours — the figure follows the disambiguation-TTL convention in the email-routing design decisions; the expiry mechanism is introduced by this feature) and the slug returns to available. Expiry releases the slug only; the conversation persists.
- Claims are bounded: at most three live claims per anchor email, and at most five confirmation sends per email per day, in addition to per-IP rate limits.
- The operator can release any claimed or confirmed slug from the operator interface.

### Email Capture and Resolution

- Capturing an email (via the slug claim, the standalone prompt for prospects who decline the claim, or the passive form's optional email field) triggers sender resolution through a new non-creating variant of the existing resolver: same priority (contact match, then organization domain match), same oldest-wins tie-break on multi-organization matches. No match resolves to nothing and creates nothing. The inbound email pipeline and its auto-creating resolver are unchanged.
- A resolved match links the conversation to the existing contact and organization. No match creates nothing automatically beyond recording the email on the conversation's prospect record; contact and organization creation remain operator actions or conversion outcomes.
- The prospect-facing response to email capture is identical whether the address matched a contact, an organization domain, or nothing — capture exposes no directory oracle.
- Once an email is captured, operator replies to the conversation are delivered to it through the platform-native outbound path (threading and send-side delivery tracking per the Prospect Conversation Loop spec; provider-side status events arrive with the Lettermint status webhook, issue #25).
- Platform mail on public-intake conversations is always sent from the configured platform address with the instance branding display name — never an inbound-route address (none exists for these conversations) and never the replying operator's personal address. This is keyed on the conversation's `public_intake` source and deliberately supersedes the organization reply-from rule in the Prospect Conversation Loop spec, including after the conversation links to an organization.
- The no-reply-channel flag clears when an email is captured.

### Reply Notification

- The natively delivered operator reply email is the notification; there is no separate notification email.
- At email capture — through any capture path, including the passive form — the prospect chooses whether operator replies are delivered by email. The choice belongs to the prospect; no email is sent to the prospect reply channel without opt-in. Without opt-in, the reply is persisted with a withheld delivery status (`withheld` — deliberately distinct from the provider-side `suppressed` failure state defined in the Prospect Conversation Loop spec) — visible to the operator as "not emailed — visible via resume link" — and reaches the prospect only via the resume URL.
- Replies on a conversation linked to an existing contact deliver to the contact's email unconditionally; prospect consent governs the prospect channel, not the established-customer path. This includes the case where the captured email itself matched an existing contact: the conversation is then linked, and replies deliver to the contact address under the established-customer rule.
- A prospect returning after any interval — including months later, within the retention bound — sees the full thread; unprompted return is a supported, expected path, not a failure mode.
- The prospect can change the notification choice from the conversation view at any time.

### Conversion

- When the operator converts a prospect (creates the organization), a confirmed slug claim held by that prospect's conversation promotes to the organization's provisioned slug in the same operation. Promotion is a race-safe conditional update; only confirmed claims promote.
- Conversion links the conversation to the new organization; the conversation's history is preserved unbroken across the transition — nothing is copied or moved.
- The prospect's resume access persists after conversion (the operator can revoke it to cut over to portal-only access).

## Non-Functional Requirements

- **Security:** Resume and confirmation tokens are high-entropy (256 bits), unique, and stored hashed at rest — a deliberate departure from the codebase's plaintext-token precedent, justified by these tokens' months-long lifetimes. Confirmation links are single-use, consumed only by explicit action, and expire with the claim. The intake, resume, and confirmation endpoints are rate-limited and send `Referrer-Policy: no-referrer`.
- **Abuse resistance:** Slug claims are bounded per anchor email and per source address per time window. Malformed or oversized submissions produce a structured error, not a server error. User-supplied values never expand unbounded runtime state. The claim-confirmation email contains only the slug and platform links, never prospect-supplied content.
- **Input handling:** Prospect-submitted content is treated as hostile input under the same sanitization rules as inbound email, including header-injection discipline on anything email-bound.
- **Privacy:** The resume URL and confirmation link are the only artifacts that grant access; neither is guessable from the slug or any public value. Invalid, expired, revoked, and purged tokens all render one identical page — token handling exposes no validity oracle.
- **Retention:** Public-intake conversations are retained 365 days after resolution (versus the standard 90-day cleanup), bounding storage while honoring the months-later return path. A resume URL past retention renders the same unavailable page as an invalid token.

## In Scope

- Public intake pages keyed by CTA source, with instance-level operator branding (introduced here).
- Anonymous conversation creation with source `public_intake` and the recorded intake source key.
- Hashed resume-token access (URL + signed cookie), with operator revoke/rotate.
- Slug claim with email anchor, scanner-safe confirmation, expiry, and operator release.
- The single slug registry shared with organization portal slugs, with claim → provisioned promotion at conversion.
- Non-creating sender resolution on email capture; derived reply-channel flagging.
- Unlinked attention-queue weighting and organization-less rendering in the operator interface.
- Prospect-visible thread and reply via the resume URL, with consent-gated reply delivery.

## Out of Scope

- Per-conversation subdomains (`abcd1234.acme.example.com`): conversations are addressed by path under the application host or resume URL. (See Rejected Alternatives.)
- Slug-based portal routing (SDD §4.1, organization portal slug) — this feature creates the registry it will consume.
- Portal account provisioning during intake; portal authentication follows the existing portal spec.
- CAPTCHA or proof-of-work challenges (revisit if abuse is observed; rate limiting is the first line).
- Custom fields, attachments, or urgency selection on the intake form.
- Notification emails to the prospect beyond the claim confirmation and consented operator replies.
- Embedding the intake form in the operator's site (iframe/JS widget); intake is a hosted page.
- Provider-side delivery status (bounce handling) — arrives with the Lettermint status webhook (issue #25).

## Dependencies

- Platform-native outbound email (implemented; #26): operator replies to captured emails travel this path with send-side delivery tracking. Provider status webhook remains open (#25).
- Existing sender resolution and attention scoring (SDD §4–§5): this feature adds a non-creating resolution variant and the unlinked weighting; the existing pipeline is unchanged.
- Instance-level branding configuration: introduced by this feature; consumed by intake pages and prospect-facing email.

## Constraints

- Wildcard TLS covers one label (`*.example.com`); per-conversation subdomains would require per-organization wildcard certificates. Conversation addressing is therefore path-based.
- Single self-hosted application; the intake surface is a route partition, not a separate service.
- Intake, resume, and confirmation URLs are served on the application host only. Organization custom domains continue to serve the customer portal exclusively and never expose intake surfaces.

## Acceptance Criteria

- Submitting a message on an intake page creates a conversation visible in the attention queue with the CTA source badge, with no authentication and no other fields completed.
- The submission response includes a resume URL; visiting it from a fresh browser session shows the conversation thread and accepts a reply.
- Visiting a claimed slug's address without the resume token or a confirmed-email link exposes no conversation content; possession of a conversation identifier alone grants nothing.
- A public-intake conversation scores above zero on creation and appears in every operator role's queue, including organization-scoped operators'.
- Claiming a slug with an email delivers a confirmation link; following it and confirming marks the claim confirmed. A prefetching link scanner that only issues GET requests consumes nothing. The same slug cannot be claimed by a second party while the first claim is live.
- An unconfirmed claim past its expiry releases the slug; the conversation and its messages remain intact.
- Capturing an email that matches an existing contact links the conversation to that contact and organization; the rendered response is identical to a capture that matches nothing.
- A conversation with no captured email displays a no-reply-channel flag; capturing an email clears it.
- After the operator converts the prospect to an organization, the confirmed slug is the organization's provisioned slug and the original conversation appears in the organization's history.
- A burst of submissions from one address beyond the rate limit receives structured rejections and creates no further conversations.
- A submission from a passive-mode page enters the attention queue with the same treatment as an active-mode submission; viewing the passive page's informational content creates no records.
- An operator reply on a conversation without notification opt-in sends no email to the prospect and is persisted with a visible withheld-delivery indicator; the same reply on an opted-in conversation delivers.
- Intake, resume, and confirmation paths requested on an organization custom domain expose nothing.

## Rejected Alternatives

- CTA form submits via email to a catchall address: loses CTA context, adds mail latency, and cannot offer the slug claim or resume access.
- Per-conversation subdomains (`abcd1234.acme.example.com`): two-level wildcards are not issuable from a single public wildcard certificate; path-based routing preserves the addressing without per-organization certificate provisioning.
- Slug URL as the access credential: memorable names are enumerable; a label must not be a key.
- Email required before conversation creation: raises intake friction and contradicts the open-intake principle; anonymous-first with identity-after preserves the net-not-filter posture.
- Separate prospect-slug and organization-slug namespaces: collision between a claimed name and a later organization slug forces manual reconciliation; one namespace with lifecycle states removes the class of conflict.
- A slug column on organizations beside the claims table: two sources of truth for one namespace reintroduces the drift the single registry exists to eliminate.
- Auto-creating a contact/organization on email capture: unconverted prospects would litter the relationship data; resolution links to existing records, creation stays an operator decision.
- Plaintext token storage following the existing precedent: a database read would expose live, months-valid resume URLs; the existing plaintext tokens are either short-lived or permanent org credentials, not comparable.
- Confirmation links consumed on GET: mail-scanner prefetch burns single-use tokens before the prospect ever clicks.
- General conversation tagging for the CTA source: a dedicated provenance field is queryable, rename-safe, and avoids designing a tagging system as a side effect.

## Resolved Decisions

Recorded 2026-07-05. Rows added in v0.3 are marked; policy rows awaiting explicit ratification are tracked in [Design Decisions: Public Intake](design-decisions-public-intake.md).

| Question | Decision | Load-bearing reason |
|----------|----------|---------------------|
| Where identity capture happens | After conversation creation, anchored to the slug claim | Zero-friction intake; the claim reframes capture as acquisition |
| What holds the claim | The email confirmation, not the slug or browser state | The slug is a label; the email is the only durable, operator-usable anchor |
| Slug namespace | One registry shared with organization portal slugs, lifecycle `available → claimed → confirmed → provisioned` (available = no row) | Eliminates claim/organization collision and later reconciliation |
| Conversation addressing | Path-based under a single wildcard domain, application host only | Public CAs do not issue two-level wildcards; custom domains stay portal-only |
| No-email conversations | Kept in the queue, flagged; only the slug reservation expires | Open intake — the message may be valuable even when unreachable |
| Claim expiry | Configurable via settings, default 72 hours | Follows the disambiguation-TTL convention; mechanism introduced here |
| Claim-offer weight per CTA | Two intake modes — active (full slug claim) and passive (informational + optional email), selected by the operator per CTA | A full-claim-only flow over-asks low-intent prospects and loses them |
| Prospect notification on operator reply | Prospect opt-in at email capture; the delivered reply is the notification; non-consented replies persist as withheld | Consent stays with the prospect; the platform exists to get conversations out of email |
| Token storage (v0.3) | Hashed at rest (256-bit random, SHA-256) | Months-lived bearer credentials; a DB read must not yield live URLs |
| Confirmation consumption (v0.3) | GET renders, explicit confirm action consumes | Mail-scanner prefetch must not burn the single-use token |
| Unlinked scoring (v0.3) | Configurable tier-equivalent score, default = standard tier; standard neglect thresholds | Net-not-filter: unknown value scores as average, not zero |
| Queue visibility (v0.3, pending ratification) | Organization-less conversations visible to all operator roles | Org scoping is workload scoping, not tenancy; an all-scoped deployment must not lose intake |
| Retention (v0.3) | 365 days after resolution for public-intake conversations | Honors months-later return while bounding storage |

## Deferred Work

- Intake-form theming beyond the operator's global branding (per-CTA visual variants): direction is operator-configured variants; not needed for the first loop.
- Slug claim surfaced during portal onboarding for email-originated prospects: same namespace and lifecycle apply; entry point is separate work.
- Prospect-channel bounce handling: when the Lettermint status webhook lands (#25), bounces should flag or clear the captured prospect email.
