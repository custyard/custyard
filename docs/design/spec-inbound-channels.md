# Inbound Mail Channels

**Version:** 0.1 — Supplements SDD v0.4 and the Prospect Conversation Loop; extends the Design Decisions: Data Model + Lettermint Integration document
**Date:** 2026-10-20
**Status:** Phases 0 to 3 implemented (see Implementation status). The Onetime Secret pilot is still open.

Visual companion: the "Inbound Mail Channels" artifact published alongside this document (topology, identity options, data model, onboarding sequence, roadmap).

## Summary

An operator connects a real support address (`support@companyname.com`) to Custyard by auto-forwarding it from their existing mail service to a secret Custyard-owned address. Each forwarded email becomes a conversation (or appends to one), the operator replies from the conversation view, and the reply reaches the customer as a correctly threaded email from the address they wrote to. Every project can carry several such channels (`support@`, `sales@`, `security@`), and the same channel abstraction later carries direct-MX and IMAP ingestion.

The first production operator is Onetime Secret, replacing a flow that is today ProtonMail labels plus manual copy-paste into a drafting assistant, in several languages. That history guides the defaults below; it does not define the feature.

## What already exists

The repository is further along than the request assumes. The design below is a delta, not a greenfield.

| Capability | Where | State |
| --- | --- | --- |
| Per-org and per-project inbound routes, provisioned in Lettermint, 256-bit callback token in the webhook URL | `Custyard.InboundRoute`, `Custyard.InboundRoutes` | Done |
| Lettermint signature verification (`t=…,v1=…` over raw body, 5-minute skew) | `Custyard.Webhooks.Adapters.Lettermint` | Done, payload shape aligned in Phase 0 |
| Sender resolution within route scope, thread matching by In-Reply-To / References scoped to org, idempotent message insert | `Purposes.SenderMatching`, `Email.ThreadMatcher`, `Message.insert_idempotent/1` | Done |
| Operator reply from the conversation view, threaded headers, async delivery queue, send-side status | `Conversations.send_reply/3`, `Email.Outbound`, `Email.OutboundQueue` | Done |
| Reply From resolution: channel → route `from_address` → operator email → instance fallback | `Conversations.reply_identity/2` | Done, channel step added in Phase 1 |
| LMTP server and IMAP poller feeding the same dispatcher | `Email.LMTPServer`, `Email.ImapPoller` | Done, IMAP is one global mailbox (replaced by per-channel IMAP in Phase 3) |
| Provider delivery-status webhook (delivered, bounced, suppressed) | `Custyard.Email.DeliveryStatus` | Done in Phase 0 |
| Auto-reply, bounce and loop detection | `Custyard.Webhooks.Triage` | Done in Phase 1 |
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
- Full MIME fidelity (calendar invites, S/MIME, remote images). Phase 2 covers attachments and sanitized HTML; inline `cid:` images followed after Phase 3.

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

Phase 3 narrowed the domain rule: forwarding channels always use the route's Lettermint catch-all domain, never the custom domain. The custom domain carries direct-MX channels (D8), and an ingress address that changed when it was verified would break forwarding rules operators had already saved.

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
| Auto-response / bulk | `Auto-Submitted` present and not `no`, `Precedence: bulk|junk|auto_reply|list`, `X-Autoreply`, `X-Autorespond`, empty `envelope.mail_from` (DSN). Not `X-Auto-Response-Suppress`: it is a request to the recipient, not a marker on the message | If it threads to a conversation, append as a system message (visually distinct, no reactivation, no notification). Otherwise write to the channel rejection log; no conversation |
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

The channel row carries `ingress_kind`: `forward` (this document), `mx` (operator points MX for a subdomain at Lettermint; From identity may be that subdomain; no forwarding hop, so SPF is meaningful again), and `imap` (per-channel credentials encrypted at rest, polled; replaces today's single global `ImapPoller` config). All three produce the same normalised delivery and enter the same triage stage. The forwarding provider hint (`proton`, `google`, `google_workspace`, `other`) is recorded on `forward` channels to drive setup copy and provider-specific triage rules. Implemented in Phase 3; see Implementation status.

### D9. Attachments and HTML (Phase 2)

Route attachment mode is set to signed URLs. An attachment worker fetches within the expiry window into a dedicated attachment directory (`ATTACHMENT_DIR`, never a static path) under a content-addressed path, records filename, declared type, sniffed type and size, and never trusts the declared filename as a path. Default per-channel cap 10 MB per message, remainder listed but not fetched. Signed URLs are never logged, never rendered to the browser, and never stored. HTML bodies are sanitised at ingest with an allowlist, images removed, and stored alongside the text body. Implemented in Phase 2; see Implementation status.

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
6. **Google Workspace admins** may block per-user forwarding. The admin routing path is the robust alternative and needs its own setup copy. *Resolved in Phase 3* by the `google_workspace` provider and `docs/ops/inbound-channels.md`.

## Roadmap

**Phase 0, prerequisites** (done). Adapter payload alignment with dedup on Lettermint `id`; capture route domain from the create-route response; provider status webhook (delivered, bounced, suppressed) so operators can see replies land. Verify the two Lettermint *confirm* items.

**Phase 1, forwarding channels** (done, pilot pending). Channel model and migrations; triage stage with own-echo, verification capture and auto-response classes; per-channel From identity with sending-domain check; setup wizard for Proton and Gmail; channel health; channels tab; conversation view badges and recipients display. Onetime Secret pilot on one `support@` channel.

**Phase 2, email fidelity** (done). CC and Reply-To handling in the composer; sanitised HTML; attachments via signed URLs; archive copy (D4); operator-sent capture and manual-forward unwrap for backlog import; rejection log UI; DSAR coverage for CC participants; language detection as an enrichment purpose.

**Phase 3, other ingress kinds** (done). Direct-MX channels on a custom inbound domain with subdomain From identity; per-channel IMAP with encrypted credentials replacing the global poller; Google Workspace admin-routing guide.

## Implementation status

**Phase 0** (commit 6c90d5b): enveloped Lettermint payload with the delivery `id` as a second dedup key; `inbound_routes.lettermint_route_domain` captured at creation and backfillable; `POST /api/webhook/email-status/lettermint` advancing `messages.delivery_status`.

**Phase 1** (custyard/custyard#32) landed the design above with these notes:

- **Model.** `Custyard.InboundChannel` and `Custyard.InboundChannelRejection`, context `Custyard.InboundChannels`. Conversations carry `inbound_channel_id` and `suspect`; messages carry `inbound_channel_id`, `to_addresses`, `cc_addresses`, `reply_to`, `authentication`, `spam_score` and `triage_class` (`customer | auto_response | suspect`). A channel is created directly in `pending_verification`; `draft` exists in the state machine but nothing writes it. Verification confirmation is accepted only from `pending_verification`.
- **Routing.** `InboundChannels.resolve_for_delivery/2` matches `data.recipient` (falling back to `To` when the metadata is absent) against the current token and a rotated token inside its grace period. A route with no channels returns `:legacy` and dispatches exactly as before. The dispatcher now returns `{:ignored, reason}` for deliveries that were deliberately dropped; the webhook controller answers 200 with `status: "ignored"`, the LMTP server answers 250, the IMAP poller marks the message seen.
- **Triage** (`Custyard.Webhooks.Triage`) implements the own-echo, provider-verification, auto-response, suspect and customer classes. Operator-sent capture and manual-forward unwrap are Phase 2 as planned. Own echoes are recorded as an `:inbound_triaged` audit event rather than a field on the outbound message. Verification senders are configurable (`:forwarding_verification_senders`); any `@google.com` sender with a "forwarding confirmation" subject is also accepted. Suspect conversations are created with `urgency: :normal` (pinned after Sieve header overrides) and `suspect: true`, skip operator notification and neglect alerts, and can be dismissed from the thread header. A contact whose only conversations are suspect does not exempt its sender; dismissing the flag does. Messages store the header To addresses, never the ingress address.
- **Reply identity.** `Conversations.reply_identity/2` returns address, name and source (`:channel | :route | :operator | :platform`). The `reply_from: :ingress_address` fallback sends from the full ingress address. `Email.Outbound` honours a customer's `Reply-To` only for customer-class messages and never for prospect conversations.
- **Sending-domain check.** `Lettermint.Client.list_domains/0` (team-level `GET /domains`, paginated) feeds `InboundChannels.check_sending_domain/2`; the result is stored on the channel and summarised as verified, pending, failed, not found or unchecked.
- **Health.** `InboundChannels.check_quiet_channels/1` runs on the scoring scheduler tick, writes a `:channel_quiet` audit event once per quiet period and sends an operator email when email is enabled. `last_delivered_at` from D7 was not added; `last_received_at` is enough for the quiet alert.
- **Retention.** `InboundChannels.sweep_expired/1` runs inside `Conversations.RetentionSweep`: rejection rows after 14 days, expired verification captures, rotated tokens past their grace period.
- **UI.** Channels tab on the organization page (the Routes tab survives as an "Advanced" disclosure inside it), setup wizard for Proton, Google and other providers with live verification capture, token reveal and rotation with confirmation, pause, resume and revoke. Conversation thread shows channel and suspect badges, per-message To, CC, Reply-To, authentication and spam score, and the composer states which identity a reply will use. Attention queue rows show the same badges.
- **Open.** Onetime Secret pilot on one `support@` channel; the Proton envelope and header check (Risks item 3) happens on that first forward.

**Phase 2** (custyard/custyard#35) landed email fidelity with these notes:

- **HTML.** `Custyard.Email.HtmlSanitizer` (on `html_sanitize_ex`) runs inside both adapters, so raw provider HTML never leaves normalisation. Allowlist: text markup, lists, headings, blockquotes, code, tables and `http`/`https`/`mailto` links; `script`, `style`, `head`, `iframe`, `object`, `embed`, `svg` and `math` blocks are removed with their contents before parsing; no `style`, `class`, `id` or handler attributes survive; images are removed outright rather than blocked (inline `cid:` images followed after Phase 3, see Follow-ups). Links open in a new tab with `rel="noopener noreferrer"`. Raw HTML over 300 KB, or markup with no text, stores nothing. The result lives in `messages.html_body`; the operator thread renders it with the plain text behind a toggle.
- **Attachments.** The adapter keeps the signed-URL descriptors in the in-memory metadata only; `Custyard.Webhooks.Purposes.Attachments` runs after the message is stored (for customer, suspect, operator-forward and operator-sent deliveries, never auto-responses) and `Custyard.Attachments.fetch_for_message/3` fetches each within the channel's `attachment_limit_mb` (default 10, 0 disables) into `ATTACHMENT_DIR/<ab>/<sha256>`, sniffs the type from the bytes and records a `message_attachments` row (`pending | fetched | skipped | failed`, with `over_limit`, `too_large`, `suspect`, `disabled`, `no_url`, `fetch_failed` as skip reasons). Attachment slots are reserved transactionally with a unique message/position and an immutable descriptor fingerprint before network I/O. A conditional database lease claims each slot, and a fencing token prevents an expired worker from overwriting a new attempt. Processing completes in the delivery request rather than a disposable task; unfinished or failed downloads return a retryable response. Replays resume the same slots and reject changed manifests. Signed URLs remain in memory only. Suspect mail is listed without downloading; clearing the flag starts recovery through Lettermint's retained webhook-delivery API. Missing permissions, expired URLs or unavailable deliveries leave the files listed with an explicit recovery retry. Recovery selects each message’s recorded inbound channel and its route’s webhook, and applies that channel’s current attachment limit, even when later messages joined the conversation through another route. Download is `GET /operator/attachments/:id`, organization-scoped, blocked while the conversation is suspect, always `Content-Disposition: attachment`, served under the sniffed type when it is on a small allowlist and `application/octet-stream` otherwise. The retention sweep excludes temporary files, allows a 24-hour grace period, and rechecks references under the same file lock as publication before deleting an orphan. Only `https` URLs with a hostname are fetched. Portal download followed after Phase 3 (see Follow-ups).
- **CC.** `Conversations.default_reply_cc/2` is the To and CC of the latest customer-class message minus the conversation's own side; the composer shows it editable and `send_reply/3` takes `:cc`, validating every address first. Outbound sends it as the CC header. Prospect conversations never carry a CC.
- **Archive copy (D4).** `inbound_channels.archive_copy`, off by default, set on the identity step of the wizard; Outbound BCCs the public address and triage's own-echo class absorbs the forwarded copy. The composer says when a copy is kept.
- **Operator-sent and manual forward.** Both require the sender to be an operator account of the organization (any role scoped to it, or a super admin) or the channel's public address, *and* a DKIM pass whose signing domain is aligned with the sender's domain (exact or parent/child). `operator_sent` appends an operator message with no delivery status, stamps `last_operator_action_at`, reactivates nothing and notifies nobody. `operator_forward` unwraps the forwarded block (`Custyard.Email.ForwardUnwrapper`: Gmail, Apple Mail, Outlook, Thunderbird, Proton, quoted or not), runs the customer pipeline with the original sender as contact, stamps `forwarded_by_operator_id` / `forwarded_by_email`, drops the forward's own authentication, spam score, CC and HTML, and does not notify. A forward that cannot be unwrapped is customer mail from the operator's address, visibly, rather than dropped. The `X-Forwarded-For` alternative from D6 is not implemented.
- **Rejection log UI.** The channels tab lists the organization's rejections from the last 14 days with reason, sender, subject and the channel or masked route address.
- **DSAR.** `Custyard.DataSubjects` finds every message an address appears on as sender, To, CC or Reply-To; `export/2` includes the body only for messages the person sent, `erase_participation/2` scrubs recipient lists and Reply-To on messages they did not send and writes a `data_subject_erasure` audit event with counts only. `mix custyard.dsar export|erase EMAIL --org ID [--yes]`. Contact-level erasure of a sender's own messages followed after Phase 3 (see Follow-ups).
- **Language.** `Custyard.Email.LanguageDetector` (function-word scoring, no dependency; en, de, fr, es, nl, pt, it) runs in the enrichment purpose and sets `conversations.language` from the first detectable message; the thread header and attention queue show it.
- **Open.** None; portal attachment download, inline `cid:` images, contact-level erasure and Reply-To display in the composer followed (see Follow-ups).

**Phase 3** (branch `agent/custyard-inbound-phase3`) landed the other ingress kinds with these notes:

- **Route custom domain.** `InboundRoutes.set_custom_domain/2` sets `inbound_settings.inbound_domain` with `PUT /routes/{id}`, and `verify_custom_domain/1` calls `POST /routes/{id}/verify-inbound-domain`. The field names and endpoints come from Lettermint's published SDK types, because the API reference page for them was unavailable. A custom domain is exact or a left-hand wildcard (`*.m.example.com` does not cover `m.example.com`), and Lettermint's own domains are refused. A failed re-check keeps an earlier verification, because mail that already arrives proves the record better than one lookup. A domain that a direct-MX channel still uses cannot be moved; the check reads the route as stored, because a page can hold a copy from before the first channel set the domain. Forwarding channels stay on the catch-all domain (see D2).
- **Direct MX.** `ingress_kind: :mx`. Creating the first channel sets the route's custom domain to the public address domain, and later channels must be on it. One Lettermint route has one custom domain, so one route serves one MX domain. Routing tries forwarding tokens first. If none match, the recipient without its `+tag` is matched against MX public addresses on a domain the custom domain covers, so `support+order-42@help.example.com` still reaches `support@help.example.com`. A direct-MX public address therefore cannot contain a `+`. Tokens now route forwarding channels only. The channel waits in `pending_verification` until `InboundChannels.check_mx/2` sees the record or the first message arrives, and it starts in `awaiting_first_message` on a domain that is already verified. Some forwarding options do not apply to direct-MX channels, and the setup refuses them: an ingress address, a provider, the ingress-address reply fallback, the archive copy (there is no mailbox to keep it) and token rotation. A domain that one of the organization's forwarding channels uses is refused, because moving its MX record would take mail away from the operator's mailbox. Replies go out from the public address, which must be a verified Lettermint sending domain. SPF is a real signal here, but triage still scores on DKIM and DMARC as for forwarded mail.
- **Google Workspace admin routing.** Provider `google_workspace`. The setup copy describes a Default routing rule that adds the full ingress address, `+token` included, as an extra recipient, so the mailbox keeps its copy. It says not to use Change envelope recipient. No confirmation email exists, so the wizard does not wait for one. Whether Google sets the added address as the envelope recipient of the extra copy is not documented. The test step and the rejection log ("no matching channel") show it on the first message.
- **IMAP.** `ingress_kind: :imap` stores the following:
  - `imap_host`, `imap_port` (default 993, implicit TLS only), `imap_username` and `imap_folder` (default `INBOX`).
  - The password, as `Custyard.Credentials` ciphertext only. This is AES-256-GCM under a dedicated `CREDENTIAL_ENCRYPTION_KEY`, bound to its column. `CREDENTIAL_ENCRYPTION_KEY_PREVIOUS` still decrypts, and a password sealed with it is re-encrypted after its next successful use. Without a key, the password cannot be saved.

  `Custyard.Email.ImapPollers` supervises one poller per channel that is `awaiting_first_message` or `active`, has a position and is not suspended. The pollers start and stop from channel broadcasts, with a five-minute sweep as a safety net.

  Each session (`Custyard.Email.ImapPoll`) does the following:
  - It runs in a task with a 120-second deadline, because Plover's TLS connect has no timeout.
  - It resolves the host to IPv4 and refuses names with any private, loopback, link-local or reserved address, and it refuses IP literals. It connects to the resolved address and checks the certificate against the name through SNI; this was confirmed against Gmail and Fastmail, where a wrong name fails the handshake. A server without an A record is reported as unresolvable.
  - It opens the folder with EXAMINE and fetches with `BODY.PEEK[]`, so no flag in the mailbox changes.
  - It lists new mail with `UID FETCH n:* (UID RFC822.SIZE)`, because Plover parses only ESEARCH replies and most IMAP4rev1 servers answer SEARCH in the older format.

  The channel stores `imap_uid_validity` and `imap_last_uid`. The first connection records the newest UID, so history is not imported. Reconnecting, such as after a login lockout or with the wizard's connection test, keeps the position, so mail that arrived in between is still imported. A changed UIDVALIDITY, or a changed server, username or folder, starts again from the newest UID.

  At most 50 messages are imported per session. Messages over 25 MB are not fetched and are logged as `too_large`, and messages the parser cannot read are logged as `unreadable`; the position moves past both. A pipeline refusal also moves the position on. A connection or database failure stops the session without advancing. So does a message whose attachments could not be stored, for up to five sessions (`imap_message_attempts`); after that the message is passed over with its attachments marked failed. Each message carries the delivery id `imap:<channel>:<uidvalidity>:<uid>`, so a retry finds the stored message, with or without a Message-ID, and resumes its attachments. Three rejected logins without a successful session in between (`imap_auth_failures`) set `imap_auth_failed_at`, which stops polling until the credentials change. Other failures count towards backoff only. A password re-encrypted under a new key is written only if the stored ciphertext is still the one the session read. Errors are stored as short codes, never server text.

  The dispatcher takes the channel (`dispatch/3`, `channel:`) instead of resolving a recipient, and it still rejects paused and revoked channels. Attachments carried in the MIME message are stored under the channel cap. This also applies to LMTP mail.

  IMAP channels have no authentication results, so suspect, operator-sent and manual-forward classification do not apply to them. `Authentication-Results` headers written by the mailbox provider are not trusted.

  `IMAP_ENABLED` and the other `IMAP_*` variables are gone. A deployment that still sets `IMAP_ENABLED` refuses to start and prints the migration steps.
- **Fix.** `Lettermint.HttpClient.list_domains/0` sent `per_page` and `cursor`, but the Team API takes `page[size]` and `page[cursor]`. Every request therefore returned the first page, and later sending domains were reported as not found.
- **Open.**
  - The Onetime Secret pilot, now covering one forward channel. Direct MX and Workspace admin routing still need a first real message each.
  - OAuth (XOAUTH2) for Gmail, Workspace and Microsoft 365 IMAP. Only app passwords are supported.
  - Writing operator replies to the IMAP Sent folder (the archive copy BCC works instead).
  - IDLE instead of one-minute polling.
  - A poll lease for multi-node Postgres deployments. Two nodes would poll the same mailbox; the position only moves forward and imports are deduplicated, but the work is doubled.
  - Wildcard custom domains are honoured but not offered in the wizard.

**Follow-ups** (branch `agent/custyard-inbound-followups`) close open items from Phases 2 and 3:

- **Reply recipient in the composer.** The composer shows the To of the next reply from `Outbound.reply_recipient/1`, the resolver delivery uses, and says when it is the customer's Reply-To.
- **Portal attachment download.** `GET /p/:org_token/attachments/:id`, which the custom-domain rewrite also serves as `/attachments/:id`. `Attachments.get_for_portal/2` serves only a fetched file on a message that is neither an internal note nor deleted, in a conversation of the portal's organization that is not suspect; anything else is the same 404. The portal thread lists the same attachments under each message. Downloads use the operator endpoint's headers through `CustyardWeb.AttachmentDownload`: always `Content-Disposition: attachment`, the sniffed type from the allowlist, `nosniff` and a sandbox CSP.
- **Channel weight in the attention score.** `inbound_channels.attention_bonus`, 0 to 30 points (0 by default), is added to the score of the channel's conversations as a `channel` component of the breakdown; it is plain points rather than a global weight, so `security@` can outrank `sales@` on the same instance. The channel card sets it. A change rescores the channel's active conversations at once instead of waiting for the five-minute sweep.
- **Contact-level erasure.** `DataSubjects.erase_subject/2`, `mix custyard.dsar erase-contact EMAIL --org ID --yes`. It does the participation erasure and also erases what the person sent. Their messages are tombstoned and emptied (body, HTML, sender, recipients, Reply-To, authentication); the rows and their Message-IDs stay so threading still works. Those messages' attachment rows are deleted, and the attachment sweep removes the files. Their contact record is deleted, the conversations it owned lose the contact and their subject, and their rejection-log entries are deleted. Operator replies keep their text, without the person's address. One transaction; the audit event carries counts only. The DSAR tooling is a Mix task, so a release cannot run it yet.
- **Inline `cid:` images.** The sanitiser keeps `<img>` only with a `cid:` source and `alt`, and drops every other image tag. IMAP and LMTP parsing records each part's Content-ID, and keeps an image part without a filename when it has one; Lettermint descriptors already carried `content_id`. At render time `CustyardWeb.InlineImages` points each `cid:` at the same message's attachment with that Content-ID, served by `GET /operator/attachments/:id/inline` only when the bytes sniffed as PNG, JPEG, GIF or WebP (never SVG). Any image it cannot resolve is dropped, so a stored `cid:` never reaches the browser. Suspect conversations fetch no attachments, so their images never load. Mail stored before this change kept no images.

## Rejected alternatives

- One Lettermint route per channel: more provider objects and webhooks for no security gain over the subaddress token on an already-random route domain.
- Replying from the ingress address: identity discontinuity for customers, and the primary mailbox loses its record.
- Reply-To pointing at the public address with a different From: confuses clients and recipients, and all replies still take the forwarding hop.
- Treating SPF failure as a spam signal on forwarding channels: SPF cannot pass through a forwarder that does not rewrite the envelope, and when it does rewrite, it passes for the wrong domain.
- Storing raw `.eml` for every delivery: Lettermint already retains it 28 days; storing a second copy multiplies the personal data footprint for a rarely used capability.
- Auto-creating contacts for CC'd participants: turns bystanders into records without any action on their part.


### Phase 2 review safeguards

- Data-subject lookups treat SQL wildcard characters literally and discard rows with no exact participant role. Erasure reads the current recipients under a write transaction and commits its count-only audit record in that transaction; an audit failure rolls back erasure.
- Outbound delivery claims a fresh message and captures its actual recipient envelope transactionally before contacting the provider. A stale queued message cannot restore previously erased CC addresses. Public-intake replies clear CC at the domain boundary and again at composition.
- Editing only a reply body preserves automatic CC updates from incoming mail. Language detection reads persisted customer messages in stable arrival order and sets the language only while it is unset.
- Retained attachment payload retrieval requires the Lettermint Team API token to have delivery-content access. [Get a specific webhook delivery](https://lettermint.co/docs/api-reference/team/webhook#get-a-specific-webhook-delivery) returns the original payload; it does not renew its attachment URLs. [Provider retention](https://lettermint.co/docs/platform/inbound-mail/attachments-and-raw-email) is 28 days. Expired attachments require retrieving the original externally or asking the sender to resend.
