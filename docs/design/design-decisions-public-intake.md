# Design Decisions: Public Intake Implementation

**Version:** 0.1
**Date:** 2026-07-05
**Context:** Supplements SDD v0.4 and the [Public Intake and Slug Claim spec](spec-public-intake.md) v0.3. Captures the implementation decisions from the 2026-07-05 design review: three independent blueprints (domain-model, security, and delivery lenses) judged by a three-judge panel and synthesized. Where a decision corrects a v0.2 spec premise, the spec carries the amendment; this doc carries the mechanism.

---

## Slug Registry

**Decision:** A single `slugs` table owns the entire namespace. No `organizations.slug` column, ever — an organization's slug is read through `has_one :slug` (status `provisioned`). This amends SDD §4.1's "has a unique portal slug" organization attribute: the slug is an attribute of the registry, not a column on organizations.

- Columns: `slug` (unique index — the namespace guarantee), `status` (`claimed | confirmed | provisioned`, CHECK-constrained), `email`, `conversation_id` (partial unique), `organization_id` (partial unique), `confirmation_token_hash` (partial unique), `expires_at`, `confirmed_at`.
- Inline CHECK `(status = 'provisioned') = (organization_id IS NOT NULL)` written via raw `execute` CREATE TABLE — SQLite cannot add constraints later, so creation is the only chance to put the pairing invariant in the schema. A migration test asserts the CHECKs fire under ecto_sqlite3.
- Lifecycle: `available` = no row. Expiry and operator release DELETE the row (no tombstones — a tombstone would block re-claim under the unique index). Lazy expiry inside `Slugs.claim/3`'s transaction handles the claim-an-expired-slug race; an hourly sweep (`Custyard.Slugs.ClaimExpiry`, DormancyChecker pattern, off in test) handles the rest.
- Format: downcase/trim, then `^[a-z0-9]([a-z0-9-]{1,61}[a-z0-9])$` (3–63 chars, DNS-label safe), reject `xn--`. Reserved words are a module attribute in code — they encode router facts and must not be operator-mutable — plus an `:additional_reserved_slugs` config escape hatch.
- Bounds: max 3 live (claimed or confirmed) rows per anchor email, counted inside the claim transaction.

**Rejected:** `slug_claims` + `organizations.slug` with app-level cross-checks (two sources of truth for one namespace — the drift class the single registry exists to eliminate); reserved list in Settings (operator-mutable security control).

## Tokens

**Decision:** Both new token classes — the conversation resume token and the slug-claim confirmation token — are 256-bit random values stored SHA-256-hashed at rest, via a new shared primitive `Custyard.Auth.Token` (`generate/0 :: {token, hash}`, `hash/1`).

This deliberately breaks the codebase's plaintext-token precedent. The existing plaintext tokens are a 15-minute login token and permanent org credentials; these are months-lived bearer URLs, and a database read must not yield live credentials. SHA-256 of 256-bit random needs no KDF; lookup stays indexed.

- **Resume token:** `prospects.resume_token_hash`, multi-use, no expiry (months-later return is a feature; retention bounds it instead). Operator-revocable (`revoked_at`) and rotatable, exposed on the operator conversation view.
- **Confirmation token:** `slugs.confirmation_token_hash`, single-use, expires with the claim. Scanner-safe consumption: GET `/c/:token` peeks (renders slug + confirm button, zero state change); POST confirms via conditional UPDATE (`WHERE ... status = 'claimed' AND expires_at > now`; 0 rows = failure). Invalid, expired, used, and purged tokens all render one identical page — no validity oracle.
- **Cookie:** standalone signed cookie `_custyard_resume` (1-year max-age, http-only, Lax) — not the Phoenix session, whose 24-hour max-age and shared operator/portal keys disqualify it. Set only on HTTP round trips (intake POST redirect; resume GET refresh). The URL is the primary credential; the cookie powers a "resume your conversation" banner.
- `/i`, `/r`, `/c` scopes send `Referrer-Policy: no-referrer`.

## Prospect Record

**Decision:** A `prospects` table, one row per public-intake conversation, created at intake — not columns on conversations. Holds `resume_token_hash`, captured `email` (write-once through the public flow), `notify_on_reply` (default false — consent off), `email_captured_at`, `revoked_at`. 1:1 enforced by a unique index on `conversation_id`.

The no-reply-channel flag is derived, never stored: `Conversations.reply_channel/1 :: {:contact, email} | {:prospect, email} | :none`. Capturing an email clears the flag with zero clearing code. The prospect row persists unchanged through linking and conversion — it is the resume credential holder and notification preference, not the identity.

Email validation is extracted from Contact into `Custyard.EmailAddress` (Contact delegates, behavior unchanged) so the two can never diverge.

## CTA Provenance

**Decision:** A dedicated nullable `conversations.intake_source_key` column storing the key string (not an FK — provenance survives config rename/delete), set once at creation, format-validated, never in the operator changeset cast list. Rendered as a tag-style badge in the queue and on the conversation view. No general tagging system.

## Scoring

**Decision:** One PR unifies the triplicated scoring formula (`calculate/1`, `calculate_with_message_count/2`, `breakdown/1`) into a single private `components/2`, then deletes the nil-org hard-zero branches and the neglect exemption.

- Organization-less conversations score with all components; the tier component comes from a new settings key `intake_config.unlinked_tier_score` (default 10 — deliberately equal to the standard tier: unknown value scores as average, net-not-filter). Neglect uses standard-tier thresholds.
- `settings.intake_config` is a new map column following the established stringify/whitelist/merge-over-defaults discipline; it also holds `slug_claim_ttl_hours` (default 72). Explicitly not a `score_weights` key — that map is multipliers-only.
- Nil-org guards land in the notification-email templates in the same PR, because newly-possible nil-org neglect notifications would otherwise crash.

## Queue Visibility and Rendering

**Decision:** Organization-less conversations are visible to and openable by all operator roles. The org-scoped queue filter gains `or is_nil(organization_id)` and `Authorization.can_access_conversation?/2` changes with it, in the same PR — visibility and access must not diverge.

Rationale: this is a single-operator-company instance; organization scoping is customer/workload scoping, not tenancy, and a deployment where every operator is org-scoped must not silently lose intake. (Security-lens dissent noted: if least-privilege is preferred, it is one clause in each of the two functions.)

Rendering: the queue card branches on nil organization ("Unlinked prospect", no tier badge — fixing a latent crash), plus a source badge, the intake-source tag badge, and an amber "No reply channel" badge. A badge, never a filter. Broadcast hygiene: a guard helper skips org-scoped PubSub topics when `organization_id` is nil (the literal topic `conversations:org:` never fires).

## Resolution and Linking

**Decision:** Two functions.

1. `SenderMatcher.resolve/1` — a new public, lookup-only, non-creating sibling of `match/1`: same priority (exact contact match with the established oldest-wins multi-org tie-break, then org-by-domain excluding the `_unmatched_` sentinel), returns `{:contact, c} | {:organization, o} | :none`, never creates rows. The webhook pipeline and its auto-creating `match/1` are untouched.
2. `Intake.capture_email/3` — one transaction: write-once prospect email capture, resolve, then link (`{:contact, c}` sets both `contact_id` and `organization_id` in one changeset — nothing else validates the pair; `{:organization, o}` sets the org only; `:none` touches nothing). Post-commit: rescore + broadcasts (org topic only when linked).

Enumeration neutrality is binding: `capture_email` returns success to web callers regardless of link outcome, and the rendered response is byte-identical across contact match, domain match, and no match.

## Web Surface

**Decision:** Controllers for the anonymous hammerable surfaces, LiveView for the token-authenticated thread.

- `IntakeController`: GET `/i/:source_key` (active/passive dead views; unknown/disabled key → 404; passive GET creates nothing), POST `/i/:source_key` (CSRF, rate-limited) → creates the conversation + prospect, sets the cookie, redirects to `/r/:token`.
- `ResumeLive` at `/r/:token` in its own live_session with a minimal `:intake` layout; an on_mount hook re-authenticates the URL-param token on every mount (nothing lives in the session — sidesteps the 24h ceiling). Thread, prospect reply (source `:prospect`, `delivery_status` nil, reactivation + rescore), notification toggle, email prompt, claim panel.
- `ClaimConfirmationController`: GET peek + POST confirm.
- **Rate limiting:** a new generic `Custyard.RateLimit` (GenServer-owned ETS, sliding window, counts every event) + `PublicRateLimit` plug for controller routes + direct `check_rate` calls in ResumeLive mount and every mutating `handle_event` — plug limits never see websocket events. Client IP extraction is extracted from LoginRateLimit's `trust_proxy_headers` discipline into `CustyardWeb.ClientIP` (LoginRateLimit delegates). Single-node ETS accepted per the single-instance constraint; documented as the multi-node upgrade point. Bucket numbers are app config, not operator settings.
- **Custom domains:** the CustomDomain plug is unchanged — `/i`, `/r`, `/c` on a customer domain rewrite into the portal scope and 404 there, which is correct: intake is an operator surface on the application host only. `i`, `r`, `c` are reserved slugs.
- **Branding:** new `settings.branding` map (name, logo_url — uploads-restricted with traversal checks, primary_color — hex-validated) rendered by the `:intake` layout and used as the From display name on prospect-facing mail.

## Intake Source Configuration

**Decision:** An `intake_sources` table (key format-locked as a public URL segment, name, mode `active|passive`, headline, intro copy, validated Q&A list, enabled flag) with CRUD in the `Custyard.Intake` context. Operator UI at `/operator/intake-sources` in the super-admin live_session with the settings double-gate pattern; slug administration (`/operator/slugs`: list, release, audit event) sits under the same gate. Intake sources and the slug namespace are instance-level public-surface configuration — settings-class, not org-scoped route management.

## Outbound and Consent

**Decision:**

- Recipient resolution falls back `contact.email → prospect.email (not revoked) → no recipient`.
- From-address: `resolve_sender_email` gains a `:public_intake → nil` branch so the platform address + branding name is used — without it, the existing operator-email fallback would leak the replying operator's personal address on prospect mail. Keyed on the conversation's source (provenance), not org presence: it deliberately supersedes the conversation-loop spec's organization reply-from rule even after the conversation links to an organization.
- Consent gates at two layers: `send_reply` inserts non-consented prospect replies with a new `delivery_status: :withheld` and skips delivery; `Outbound.deliver/1` independently refuses non-consented prospect-channel sends. Contact-email recipients deliver unconditionally (established-customer path). `:withheld` renders as "not emailed — visible via resume link". The name is deliberately not `suppressed`, which the conversation-loop spec reserves for the provider-side suppression-list failure arriving with the #25 status webhook; consent-withheld is an expected state, provider-suppressed is a delivery failure, and the two must stay distinguishable. Enum becomes `[:pending, :sent, :failed, :bounced, :withheld]` (code-only, TEXT column).
- Claim-confirmation email: composed directly via Swoosh/Mailer (LoginEmail pattern), platform From, body contains only the slug and platform links — never prospect content; bounded to five sends per claim email per day (RateLimit bucket keyed by the downcased email). Header sanitization is extracted from Outbound privates into shared `Custyard.Email.Headers`.
- Retention: `cleanup_resolved_conversations` splits — 90 days (unchanged) for other sources, 365 days for `public_intake`. A dead resume URL renders the uniform unavailable page.

## Conversion

**Decision:** `Organizations.convert_prospect/2`, super-admin gated. Step 1: the existing `create_organization/1` unchanged, while the org has zero conversations — Lettermint provisioning failure must compensate-delete before any conversation is linked, because organizations→conversations is ON DELETE CASCADE. Step 2, one transaction: race-safe conditional slug promotion (only `confirmed` claims), contact creation from the captured email when present, conversation link (source stays `public_intake` as provenance). Transaction failure compensates by deleting the org (cascade-safe: it is conversation-free at that point). Post-commit: rescore, broadcasts, `:prospect_converted` audit event. Nothing is copied or moved; resume access persists (revocable).

## PR Stack

Nine stacked PRs, linear off `main`, each green against the full CI gate set (compile --warnings-as-errors, format, credo --strict, sobelow --exit, mix test) on its own:

| # | Branch theme | Scope |
|---|--------------|-------|
| 1 | scoring | Unify formula triplication; unlinked weighting via `settings.intake_config`; nil-org neglect + notification-template guards |
| 2 | queue | Nil-org rendering/crash fix, source badge, visibility + authorization change, broadcast hygiene |
| 3 | intake domain | `prospects`, `intake_sources`, `:public_intake` source, `Custyard.Auth.Token`, `SenderMatcher.resolve/1`, `Custyard.Intake` context, factories |
| 4 | rate limiting | Generic `Custyard.RateLimit`, `PublicRateLimit` plug, `ClientIP` extraction |
| 5 | operator config | Intake-sources CRUD UI, `settings.branding` + UI |
| 6 | public surface | `/i` + `/r` routes, intake controller, resume LiveView, `:intake` layout, cookies |
| 7 | slug claim | `slugs` registry, claim/confirm/expiry/release, confirmation email, `/c` routes, operator slugs UI |
| 8 | outbound | Prospect delivery fallback, consent gate + `:suppressed`, From-address fix, retention split |
| 9 | conversion | `convert_prospect/2` + operator conversion UI |

Ordering rationale: scoring substrate first (with guard fixes so nothing new can crash), queue safety before any surface exists, domain model before consumers, the rate limiter strictly before any public route, operator config before the public surface, `/i` and `/r` in one PR so the post-submit redirect target always exists, slug claim isolated, outbound/consent isolated, conversion last.

## Defaults Adopted Pending Ratification

Each is deliberate and each is a small change if vetoed — ratify before the referenced PR merges:

1. **Queue visibility to all roles** (PR 2) — security-lens dissent preferred admin+ only; one clause in each of two functions to change.
2. **Compensating delete on conversion failure** (PR 9) — alternative was leave-org-and-retry; naive retry duplicates orgs.
3. **Rate-limit numbers as app config**, not operator settings (PR 4).
4. **Resume access persists after conversion** (PR 9) — revocation/rotation exists if portal-only cutover is preferred.
5. **Conversion prefills the org domain from the claim email but never auto-sets it** (PR 9) — freemail domains would match-link every same-domain prospect.
6. **One live slug claim per conversation** (PR 7) — swapping requires expiry or operator release.
7. **An intake conversation auto-linked to an existing org appears in that org's portal request list** (PR 3) — consistent with email intake.
