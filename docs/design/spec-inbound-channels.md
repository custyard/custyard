# Inbound Mail Channels

**Version:** 0.1 — Supplements SDD v0.4 and the Prospect Conversation Loop; extends the Design Decisions: Data Model + Lettermint Integration document
**Date:** 2026-10-20
**Status:** Design. No code. Functional impacts and decisions recorded here are the input to implementation planning.

Visual companion: the "Inbound Mail Channels" artifact published alongside this document (topology, identity options, data model, onboarding sequence, roadmap).

## Summary

An operator connects a real support address (`support@companyname.com`) to Custyard by auto-forwarding it from their existing mail service to a secret Custyard-owned address. Each forwarded email becomes a conversation (or appends to one), the operator replies from the conversation view, and the reply reaches the customer as a correctly threaded email from the address they wrote to. Every project can carry several such channels (`support@`, `sales@`, `security@`), and the same channel abstraction later carries direct-MX and IMAP ingestion.

The first production operator is Onetime Secret, replacing a flow that is today ProtonMail labels plus manual copy-paste into a drafting assistant, in several languages. That history guides the defaults below; it does not define the feature.

## What already exists

The repository is further along than the request assumes. The design below is a delta, not a greenfield.

| Capability | Where | State |
| --- | --- | --- |
| Per-org and per-project inbound routes, provisioned in Lettermint, 256-bit callback token in the webhook URL | `Custyard.InboundRoute`, `Custyard.InboundRoutes` | Done |
| Lettermint signature verification (`t=…,v1=…` over raw body, 5-minute skew) | `Custyard.Webhooks.Adapters.Lettermint` | Done, payload shape outdated (see Risks) |
| Sender resolution within route scope, thread matching by In-Reply-To / References scoped to org, idempotent message insert | `Purposes.SenderMatching`, `Email.ThreadMatcher`, `Message.insert_idempotent/1` | Done |
| Operator reply from the conversation view, threaded headers, async delivery queue, send-side status | `Conversations.send_reply/3`, `Email.Outbound`, `Email.OutboundQueue` | Done |
| Reply From resolution: route `from_address` → operator email → instance fallback | `Conversations.resolve_sender_email/2` | Done, becomes channel-level |
| LMTP server and IMAP poller feeding the same dispatcher | `Email.LMTPServer`, `Email.ImapPoller` | Done, IMAP is one global mailbox |
| Provider delivery-status webhook (delivered, bounced, suppressed) | — | Open (custyard/custyard#25 lineage, still listed Partial in sdd-status) |
| Auto-reply, bounce and loop detection | — | Absent |
| HTML body rendering, attachments, CC/Reply-To handling | — | Absent (text body only, single recipient) |

The one conceptual gap is that routes are documented as "invisible infrastructure" while the forwarding integration needs an operator-facing object with an address, a lifecycle and a health state. That object is the channel.

## Terminology

- **Conversation** is Custyard's thread. The portal calls it a request. One inbound email that does not match an existing thread creates one conversation.
- **Route** is the existing per-org or per-project Lettermint-backed ingress with a callback token. Unchanged.
- **Channel** (new) is one public address an operator receives mail at, bound to a route, with its own secret ingress address, From identity, verification state and health.
- **Public address** is what customers see and write to (`support@companyname.com`).
- **Ingress address** is what the operator's mail service forwards to (`support+<token>@<route-domain>`). Customers never see it.

## Goals

- An operator with only a mailbox and admin access to its forwarding settings can connect a channel in under ten minutes with no DNS change.
- Every message a customer sends to the public address appears in the attention queue attributed to the right organization, project, channel and contact, or in the unmatched queue, never nowhere.
- Operator replies arrive threaded in the customer's mail client, from the public address, and the customer's next reply lands on the same conversation.
- The operator's primary mailbox keeps an independent record of the customer side of every exchange by construction, and optionally of the operator side.
- Nothing about a forwarding loop, an auto-responder, a provider verification email or a bounce can create a customer conversation or trigger an operator notification.
- Multi-channel per project from day one; direct MX and IMAP channels later without a second model.

## Non-Goals

- Shared-inbox collaboration features (assignment, collision detection, canned replies). Single-operator MVP assumption from the SDD holds.
- Replacing the operator's mail service. Custyard is downstream of it.
- Outbound campaigns, newsletters, or any send not a reply in a conversation.
- Full MIME fidelity (inline images, calendar invites, S/MIME). Phase 2 covers attachments and sanitized HTML only.

## Lettermint facts the design depends on

Verified against the Lettermint documentation on 2026-10-20. Items marked *confirm* must be checked with a real test message before implementation.

- Every inbound route gets a catch-all domain `<route-id>.lettermint.app` where the route id is a random 10-character string. Any local part reaches the route; plus addressing is parsed and delivered as `data.subaddress`. No DNS needed.
- A route can be given one custom catch-all domain (exact or wildcard subdomain) by publishing `MX 10 lettermint.mx`. Plus addressing works there too.
- Webhook envelope is `{id, event: "message.inbound", timestamp, data}`. `id` is reused on retries and is the documented dedup key. `data` carries `from {email,name}`, `to[]`, `cc[]`, `recipient` (envelope recipient, the documented routing key), `subaddress`, `reply_to`, `envelope.mail_from`, `body {text, html}`, `headers[]` as `{name, value}` pairs, `authentication_results {spf, dkim, dmarc}`, `is_spam`, `spam_score`, `attachments[]`, and `raw {url, expires_at}`.
- `headers[]` excludes "standard address, subject and date headers" but does carry `Message-ID` (the documented example shows it), so `In-Reply-To` and `References` are expected there too and threading does not need the raw `.eml`. Still worth one check against a real reply during the pilot.
- Messages at or above the route spam threshold (default 5) are quarantined and send no webhook. Release is manual in the dashboard or `POST /v1/messages/{id}/process`.
- Attachments arrive as Base64 or as signed URLs, per route setting. Raw message and attachments are retained 28 days. Signed URLs are secrets.
- Lettermint B.V., Zwolle, Netherlands. Email data hosted and processed in the EU, GDPR Article 28 processor with a public DPA and subprocessor list. The DPA names two different legal entities across versions; confirm the contracting entity before the first customer channel.
- The Team API wraps the create-route response in `data` (`POST /projects/{id}/routes`), while `GET /routes/{id}` returns the route unwrapped. The route object carries `inbound_route_domain`, `inbound_address` (compatibility address), `inbound_domain` and `inbound_domain_verified_at`. Before Phase 0 the client read `id` at the top level and discarded the domain.
- Lettermint issues one `whsec_` signing secret per webhook, so the status webhook has its own secret (`WEBHOOK_SECRET_LETTERMINT_STATUS`), separate from the inbound route webhook's.

## Forwarding provider behaviour

| | Proton Mail | Gmail / Google Workspace (per user) | Google Workspace (admin routing) |
| --- | --- | --- | --- |
| Availability | Paid plans only | All | Admin console, Default routing / recipient address map |
| Confirmation step | Sends an email with an "Accept forwarding" button to the destination; forwarding starts after acceptance | Sends "(#code) Gmail Forwarding Confirmation" with a code and a link to the destination; code must be entered back in Gmail settings | None, admin action |
| Filters | Conditions (subject, sender, attachment) | All-or-nothing, or per-filter "Forward it" | Per-rule |
| Original kept | Yes | Choice: keep in inbox (recommended) or archive | Dual delivery |
| Sent mail forwarded | No | No | Configurable |
| From header on forwarded copy | Original sender preserved (true forward) | Original sender preserved; adds `X-Forwarded-To` / `X-Forwarded-For` | Original preserved |
| Envelope sender | Not documented; *confirm* with a test message | Rewritten to the forwarding account (SRS-style `+caf_=` form); ARC headers added | Google |
| Authentication at Lettermint | DKIM of the original domain passes if unmodified; SPF evaluates the forwarder; DMARC passes via DKIM alignment where the sender signs | Same | Same |
| Re-forwarding | Mail that was itself forwarded cannot be forwarded again | Not forwarded if the message is spam | — |
| Privacy note | Forwarding to a non-Proton address disables end-to-end encryption for all mail to and from that address | Standard Google processing | Standard |

Two consequences shape the onboarding flow:

1. The confirmation email lands on the ingress address, i.e. in Custyard. Custyard must recognise it and show the code or link to the operator in the channel setup screen rather than filing it as a customer conversation. Without this the operator has no way to complete the Gmail step.
2. SPF results on forwarded mail are meaningless as a trust signal. DKIM and DMARC-via-DKIM are the signals to display and score on. Treat an SPF failure on a forwarding channel as expected.

## Decisions

### D1. Channel is a first-class, operator-visible object under a route

A route stays the Lettermint-backed ingress with org and project scope. A channel is one public address bound to that route. One route can carry many channels; every channel has exactly one route. The project is the "product" in the request: project routes carry project channels, the general route carries org-wide channels.

Why not one Lettermint route per channel: the route domain is already unguessable and the subaddress distinguishes channels at zero marginal Lettermint cost. One route per project also keeps the existing dispatcher, dedup scope and route-context resolution intact. A custom inbound domain binds to a route, so `onboarding.companyname.com` serving several `+token` channels is the natural shape.

### D2. Ingress address format

`<local>+<token>@<ingress-domain>` where `local` mirrors the public address local part for operator readability, `token` is 20 characters from the Crockford base32 alphabet (100 bits, generated with `:crypto.strong_rand_bytes/1`, lowercase so case-insensitive matching cannot weaken it), and `ingress-domain` is the route's Lettermint domain by default or the route's verified custom domain when present.

The 10-character Lettermint route id already prevents guessing on the default domain. The token matters on a custom domain, where the domain is guessable, and it gives the operator a per-channel secret to rotate without touching the route. Rotation issues a new token, keeps the old one valid for a configurable grace period (default 7 days) so a forwarding rule can be updated without loss, then retires it.

Routing rule: `data.recipient` is the only routing input. Local part and subaddress are matched against active channel tokens on the route; `To`/`Cc` are never used for routing. A delivery on a route with no matching channel is logged to the route's rejection log and acknowledged with 2xx so Lettermint does not retry. Routes created before channels exist keep working through an implicit legacy channel until migrated.

### D3. Reply identity: From is the public address, no Reply-To override

Operator replies are sent `From: "<Org or channel display name>" <support@companyname.com>`. No `Reply-To`. Customers reply to the address they wrote to, the reply lands in the operator's primary mailbox, the forwarding rule carries it to Custyard, and In-Reply-To matches the conversation.

This requires `companyname.com` to be a verified sending domain in Lettermint: DKIM CNAMEs and an SPF include on the root domain alongside the existing provider. Both Proton and Google tolerate additional DKIM selectors; the SPF 10-lookup limit is the only practical hazard and is checked during channel setup.

Why this and not the alternatives:

- Replying from the ingress address or from a dedicated subdomain (`support@onboarding.companyname.com`) is the lower-DNS-risk option and is cleaner for authentication, but customers then receive mail from an address other than the one they wrote to, and the operator's mailbox stops being a record of the exchange. Two years of support history say identity continuity is what customers rely on. This option is kept as the From identity for direct-MX channels (D8), and as a fallback when an operator cannot change root-domain DNS.
- `From: support@onboarding…` with `Reply-To: support@companyname.com` is DMARC-clean but confuses recipients and some clients, and every customer reply then takes the forwarding hop anyway. Rejected.
- Round-tripping replies through the operator's mail service (SMTP via Proton Bridge or Gmail) would give the mailbox a complete record but puts credentials for the primary mailbox in Custyard. Rejected for the forwarding integration; it is an IMAP-channel option later.

The From identity lives on the channel. `inbound_routes.from_address` becomes the route-level fallback and `Conversations.resolve_sender_email/2` gains a channel step ahead of it. The conversation-loop spec's "one sending identity per organization" decision is superseded by this document for organizations with channels; the reason it gave (no per-project routes yet) no longer holds.

### D4. Archive copy of operator replies is opt-in per channel

With D3 the operator's mailbox holds every customer message but none of the operator's replies. A channel option "keep a copy of replies in the mailbox" BCCs each outbound reply to the public address. That copy is forwarded straight back into Custyard, so the triage stage (D6) must recognise Custyard's own Message-IDs before sender matching runs. Today `SenderMatching` would resolve `support@companyname.com` as a new contact in the org before the dedup check fires; that ordering must change regardless of this option.

Default off. On for the Onetime Secret pilot, where the mailbox is the current system of record and will remain so during migration.

### D5. Conversation and message data captured from email

Conversation gains `inbound_channel_id` (nullable; set at creation from the matched channel, carried by subsequent messages). Messages gain `to_addresses`, `cc_addresses`, `reply_to`, `authentication` (compact map: dkim/spf/dmarc result and the DKIM domain), `spam_score`, `provider_delivery_id` (Lettermint's top-level `id`, unique index, the documented dedup key alongside the existing Message-ID dedup), and `html_body` (Phase 2, sanitised at ingest). Raw `.eml` URLs are never stored; `lettermint_message_id` is enough to fetch within the 28-day window if an operator needs the original.

CC'd parties are participants of the message, not contacts. They are stored on the message, shown in the thread, and included on replies by default (reply-all semantics with CC visible and editable in the composer). The open-intake "net" principle applies to senders, not to bystanders. If a CC'd person later writes in, they become a contact through the normal path.

Inbound `reply_to`, when present and valid, is the recipient of the operator's reply instead of `from.email`. Shown in the thread when it differs.

### D6. Triage stage before sender matching

A new synchronous step runs after signature verification and channel resolution, before `SenderMatching`. It classifies the delivery and short-circuits everything that must not become a customer conversation:

| Class | Signal | Action |
| --- | --- | --- |
| Own outbound echo | Message-ID matches a Custyard outbound message | Record delivery to the mailbox on the existing message; no insert, no contact, no notification |
| Operator-sent capture | `from.email` is an operator account or a configured channel-owned address, Message-ID unknown, In-Reply-To or References match a conversation | Append as `source: :operator`, `origin: :email`; no reactivation; no notification |
| Operator manual forward | From is operator-owned, subject begins with a forward prefix or body contains a forwarded-message block, no thread match, DKIM pass for the operator's domain | Unwrap: extract original From, Date and body from the forwarded block; create or append with the original sender as contact; stamp `forwarded_by_operator_id`. This is the backlog-import path for existing Proton-labelled threads |
| Provider verification | From `forwarding-noreply@google.com` or Proton's forwarding notification sender, channel in `pending_verification` | Extract code and link, store on the channel with a 24-hour TTL, broadcast to the setup LiveView, acknowledge; never a conversation |
| Auto-response / bulk | `Auto-Submitted` present and not `no`, `Precedence: bulk|junk|auto_reply`, `X-Autoreply`, `X-Auto-Response-Suppress`, empty `envelope.mail_from` (DSN) | If it threads to a conversation, append as a system message (visually distinct, no reactivation, no notification). Otherwise write to the channel rejection log; no conversation |
| Spam-flagged, unauthenticated | `is_spam` true or DKIM and DMARC both fail on a sender not already a contact | Still create (open intake), but `urgency: :normal` floor, a `suspect` badge, excluded from notifications, quick-dismiss available. Existing contacts are exempt from the badge |
| Customer mail | Everything else | Existing `SenderMatching` path |

The operator-sent and manual-forward classes require an authenticated operator identity: `from.email` matching an operator account is not sufficient on its own because From is forgeable. Require DKIM pass with the signing domain equal to the operator address domain, or the message arriving via a channel whose forwarding source is that same mailbox and whose `X-Forwarded-For` names it. Without that, the message is treated as customer mail from an unknown sender.

The rejection log stores sender address, subject, classification and timestamp for 14 days so an operator can answer "did my customer's mail get lost?", then is swept with the existing retention job.

### D7. Channel lifecycle and health

States: `draft` → `pending_verification` → `awaiting_first_message` → `active`, with `paused` and `revoked` reachable from any state after draft.

- `pending_verification` is entered when the ingress address is shown to the operator. The setup screen waits for the provider confirmation (D6) and shows the code or link live. A channel left here more than 7 days is flagged in the admin view.
- `awaiting_first_message` after confirmation until the first customer delivery, with a "send yourself a test email" prompt.
- `active` tracks `last_received_at` and `last_delivered_at`. A channel that was receiving mail and has gone quiet for a configurable window (default 72 hours) raises an operator notice: forwarding rules get silently disabled when passwords change or plans lapse, and this is the only way Custyard can tell.
- `paused` stops conversation creation but keeps the rejection log, so an operator can inspect what would have arrived.
- `revoked` retires all tokens immediately. Used on offboarding or a suspected leak.

Channel management, token reveal and rotation are admin-only and produce audit events. The ingress address is shown in full during setup and on explicit reveal only; lists show the public address and a masked ingress.

### D8. Channel sources beyond forwarding

The channel row carries `ingress_kind`: `forward` (this document), `mx` (operator points MX for a subdomain at Lettermint; From identity may be that subdomain; no forwarding hop, so SPF is meaningful again), and `imap` (per-channel credentials encrypted at rest, polled; replaces today's single global `ImapPoller` config). All three produce the same normalised delivery and enter the same triage stage. The forwarding provider hint (`proton`, `google`, `other`) is recorded on `forward` channels to drive setup copy and provider-specific triage rules.

### D9. Attachments and HTML (Phase 2)

Route attachment mode is set to signed URLs. An attachment worker fetches within the expiry window into Custyard's `UPLOAD_DIR` under a content-addressed path, records filename, declared type, sniffed type and size, and never trusts the declared filename as a path. Default per-channel cap 10 MB per message, remainder listed but not fetched. Signed URLs are never logged, never rendered to the browser, and never stored. HTML bodies are sanitised at ingest with an allowlist, remote images blocked by default, and stored alongside the text body. Until Phase 2, text body with the existing `strip_html` fallback stands.

### D10. Portal and reply visibility

Email-sourced conversations follow the existing portal rules: a contact with portal access sees the thread, including operator replies, and portal replies append to the same conversation. Internal notes and the authentication badge are operator-only. Nothing about channels is portal-visible.

## Privacy and compliance

**Processing chain.** Customer → operator's mail provider → Lettermint (EU) → Custyard (operator-hosted, region of their choosing). Each hop is a processor the operator must list. Custyard ships a per-channel "data path" panel that names the hops and links the Lettermint DPA, so the operator can paste it into their records of processing.

**Minimisation.** Custyard stores the parsed text body, sanitised HTML when enabled, the addresses needed to reply, a compact authentication summary and the spam score. It does not store signed URLs, raw messages, `spam_symbols`, `envelope.remote_ip`, or the full header list. Lettermint's 28-day raw retention is documented to the operator as a provider fact, not a Custyard feature.

**Retention.** Conversations and messages inherit the existing retention sweep. The channel rejection log is 14 days. Verification codes are 24 hours. Rotated tokens are deleted at the end of the grace period.

**Logging.** No addresses, subjects or bodies at info level or above; webhook logs carry the delivery id and the truncated callback token already used today. Sentry scrubbing extends to the new fields.

**Proton end-to-end encryption.** Setting up a forwarding channel from Proton disables end-to-end encryption for all mail to and from that Proton address. The setup screen states this before the operator creates the forwarding rule.

**Access.** Channel creation, token reveal, rotation and the archive-copy option are admin actions with audit events. Agents see the public address and channel health only.

**Data subject requests.** Export and erasure by contact must cover messages where the person is a CC participant, not only a sender. This is a dependency on the contact-level DSAR tooling and is listed as a Phase 2 item.

**Forwarded-mail trust.** The thread shows a per-message authentication badge (DKIM domain and result). Operators are told in the setup copy that an authentication pass does not make a request safe to act on; account changes still need out-of-band verification. This matches Lettermint's own guidance.

## Functional impacts by surface

**Attention queue.** New columns: channel badge on each row, `suspect` badge, system-message rows excluded from scoring. Score inputs gain the channel (a `security@` channel can carry a higher base weight than `sales@`), configured in the existing scoring settings.

**Conversation view.** Per-message From, To, CC, date and authentication badge; quoted-text collapse; Reply-To shown when it differs; the composer shows the From identity and the recipients with editable CC; a "copy kept in your mailbox" indicator when D4 is on; delivery indicator extended with provider states once the status webhook lands.

**Organization and project pages.** The routes tab becomes a channels tab. Route internals (callback URL, webhook purposes) move behind an "Advanced" disclosure. Channel cards show public address, state, last received, and provider.

**Settings.** Verified sending domains list (read from Lettermint, with the DNS records to publish), so D3 can be validated at channel creation rather than at first send.

**Notifications.** Suppressed for system, suspect and operator-sent messages; a new channel-health notice; a verification-captured notice during setup.

**Operator onboarding.** A guided setup per provider: pick public address, choose project, show ingress address with copy button and Proton encryption notice where relevant, wait for and display the confirmation, send a test message, confirm first delivery, optionally add the sending domain for D3 or fall back to a subdomain identity. Each step is resumable; the channel state machine is the progress indicator.

## Risks and items to confirm before implementation

1. **Lettermint payload shape.** *Resolved in Phase 0.* The adapter now accepts the enveloped event (`from` as an object, `headers` as an array of pairs) and keeps the legacy flat shape for fixtures. Dedup uses the top-level delivery `id` as a second key.
2. **Threading headers in `headers[]`.** *Resolved by documentation.* The documented example carries `Message-ID` in `headers[]`, so threading headers are delivered and no raw `.eml` fetch is needed. One check against a real reply remains on the pilot checklist.
3. **Proton envelope and header behaviour** on forwarded mail is undocumented. One test forward and a header inspection settle it, and the setup wizard can do that inspection automatically on the first delivery.
4. **Root-domain sending verification** for D3 depends on the operator's willingness to edit DNS on their primary mail domain. The subdomain fallback is designed in; the setup copy must make the trade-off explicit.
5. **Webhook secrets** are per source today (`WEBHOOK_SECRET_LETTERMINT`, optionally keyed by callback token). Lettermint issues one signing secret per webhook. Channel creation must not create new webhooks; one webhook per route stays the rule.
6. **Google Workspace admins** may block per-user forwarding. The admin routing path is the robust alternative and needs its own setup copy.

## Roadmap

**Phase 0, prerequisites.** Adapter payload alignment with dedup on Lettermint `id`; capture route domain from the create-route response; provider status webhook (delivered, bounced, suppressed) so operators can see replies land. Verify the two Lettermint *confirm* items.

**Phase 1, forwarding channels.** Channel model and migrations; triage stage with own-echo, verification capture and auto-response classes; per-channel From identity with sending-domain check; setup wizard for Proton and Gmail; channel health; channels tab; conversation view badges and recipients display. Onetime Secret pilot on one `support@` channel.

**Phase 2, email fidelity.** CC and Reply-To handling in the composer; sanitised HTML; attachments via signed URLs; archive copy (D4); operator-sent capture and manual-forward unwrap for backlog import; rejection log UI; DSAR coverage for CC participants; language detection as an enrichment purpose.

**Phase 3, other ingress kinds.** Direct-MX channels on a custom inbound domain with subdomain From identity; per-channel IMAP with encrypted credentials replacing the global poller; Google Workspace admin-routing guide.

## Rejected alternatives

- One Lettermint route per channel: more provider objects and webhooks for no security gain over the subaddress token on an already-random route domain.
- Replying from the ingress address: identity discontinuity for customers, and the primary mailbox loses its record.
- Reply-To pointing at the public address with a different From: confuses clients and recipients, and all replies still take the forwarding hop.
- Treating SPF failure as a spam signal on forwarding channels: SPF cannot pass through a forwarder that does not rewrite the envelope, and when it does rewrite, it passes for the wrong domain.
- Storing raw `.eml` for every delivery: Lettermint already retains it 28 days; storing a second copy multiplies the personal data footprint for a rarely used capability.
- Auto-creating contacts for CC'd participants: turns bystanders into records without any action on their part.
