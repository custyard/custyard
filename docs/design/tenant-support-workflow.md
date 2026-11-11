# Tenant support workflow implementation

Custyard is an open-source customer onboarding platform. The deployment operator runs an instance. Each tenant owns its staff, subdomain or custom domain, branding, support addresses and provider connection; customer organizations belong to that tenant. Threads, contacts, projects, tasks and labels stay within this boundary.

This implementation follows the [Lettermint audit](../research/2026-10-27-lettermint-support-readiness.md). The [email setup guide](../ops/lettermint-email-setup.md) describes the deployment and provider steps.

## Product behavior

Tenant staff work across their tenant's customer organizations. Existing organization-scoped accounts retain their narrower access during migration. An instance administrator can explicitly grant tenant access after reviewing the account; the grant rotates its session claim and is audited. Tenant administrators can add and remove tenant staff. Customer access continues to use the existing private portal credential.

New shared support routes automatically resolve the sender within the receiving tenant. Existing contacts take precedence; business domains group customers, while personal addresses create sender-named organizations keyed by email. Existing explicitly customer-bound routes retain their original routing. Message-ID, In-Reply-To and References establish thread continuity. A conservative subject fallback applies to a reply-prefixed subject from the same sender/customer with exactly one recent match. New messages sharing a subject are kept separate; ambiguous matches never choose an arbitrary thread.

Replies address the latest participant or their Reply-To, with appropriate reply-all recipients. The reviewed recipient, channel and delivery payload are recorded before sending. A changed recipient stops a stale composer. Known rejections can be retried with stable idempotency; an uncertain acceptance requires provider reconciliation and cannot be blindly resent. A nondefault tenant uses its own selected support channel and Project token, including public-page replies and optional notification emails.

Tasks are internal by default. Their UTC deadlines remain discoverable after a conversation is resolved or snoozed. Explicitly shared tasks appear read-only on customer pages. Tenant-owned labels can be created, assigned, removed and used to filter the queue; labels remain internal.

## Public pages remain part of onboarding

The existing intake `/i/:source_key`, private conversation `/c/:token`, claim confirmation `/claim/:token`, and organization portal `/p/:org_token` surfaces are preserved. Public conversation access remains token-based with revocation/rotation enforcement. Tenant hosts cannot access another tenant's public token. Tenant branding and canonical URLs carry through the welcome, intake, conversation, sign-in and confirmation experiences.

The private conversation page updates shared tasks live and rechecks revoked access. Internal tasks, staff notes and labels remain private. Email capture keeps its consent and identity-enumeration behavior, with customer resolution restricted to the conversation's tenant. Configured receipts, claim confirmations and staff notifications use that tenant's recipients, sender and credentials; missing setup never falls back to another tenant's mailbox or token.

## Audit disposition

| Finding | Disposition | Implemented behavior or remaining boundary |
| --- | --- | --- |
| L01 Separate tokens | Implemented | `LETTERMINT_PROJECT_TOKEN` sends; `LETTERMINT_TEAM_TOKEN` manages. Legacy `LETTERMINT_API_KEY` is sending-only. Encrypted tenant credentials override installation defaults; installation defaults apply only to the default tenant. |
| L02 Production mocks | Implemented | Missing production management credentials select a disabled client with actionable failure. |
| L03 Project binding | Implemented | Tenant email setup selects and checks the provider project. Bound routes prevent silently switching projects. |
| L04 Real webhooks | Implemented with manual provider step | Import a real receiving route, bind provider webhook ID, exact callback URL, scope and signing secret. Local processing toggles are distinguished from provider webhooks. |
| L05 Signing/recovery | Implemented | Separate encrypted route and status secrets, opaque status callbacks, actual provider webhook IDs and tenant-scoped attachment recovery. |
| L06 Readiness | Implemented; live pilot required | Selected-project domain checks, separate receive/send observations, delivered reply and genuine returning header match. Tests, replays, echoes and suspect mail cannot complete setup. |
| L07 Discovery | Implemented | Queue setup prompt, persistent setup link, resumable four-step checklist, prerequisites and customer detail navigation. |
| L08 Misleading banners | Implemented | Capability-specific saved/missing/checked and observed states replace global secret-presence banners. |
| L09 Tenant/customer model | Implemented | Explicit tenant ownership, scoped staff/hosts and customer intake, with unchanged private public-page credentials. |
| L10 Reply-all recipient | Implemented | Latest participant and CC selection are shared by preview and delivery; stale recipient drafts are protected. |
| L11 Delivery recovery | Implemented with conservative unknown handling | Stable idempotency, bounded safe diagnostics, recorded rejection/unknown distinction and explicit retry for known failures. Unknown acceptance remains a manual provider check. |
| L12 Tasks | Implemented | Private defaults, UTC create/edit fields, validation, due-task queue and live shared-task display. |
| L13 Labels | Implemented | Tenant definitions, assignment/removal and queue filtering, including unlinked public intake. |
| L14 Historical fidelity | Deliberately later | Newly captured mail forms the thread. Historical import, thread merge and outgoing attachments are not included in this plan's first four slices. |
| L15 Phoenix/white-label UX | Implemented | Tenant branding/upload, scoped authorization and post-network checks, asynchronous provider checks, progress/error feedback and reachable scrolling setup. |
| L16 Operations | Partly implemented; remainder later | Last receipt/roundtrip evidence and provider activity/quarantine guidance are included. Automated provisioning, remote orphan reconciliation and cleanup remain later work; the primary setup path imports manually created provider resources. |

## Review before the draft pull request

Independent reviews covered tenant access and public pages, provider configuration and setup, and support mail delivery. Eight confirmed issues were corrected with regression tests:

| Issue | Correction |
| --- | --- |
| Claim confirmation on a different tenant host | Both viewing and consuming a claim check the conversation's tenant. |
| Legacy staff mutations of foreign unlinked threads | The locked mutation query checks the organization's tenant; orphaned staff have no access. |
| Returned copies of public-page replies | Echo detection includes tenant conversations without a customer organization. |
| Ambiguous email References | Prospect eligibility is applied before limiting candidate threads, preserving ambiguity detection. |
| Duplicate provider IDs across tenants | The delivery-status update itself uses the webhook's tenant boundary. |
| CC or archive delivery counted as customer delivery | Setup evidence requires delivery to the primary recipient. |
| Stale administrator access in an open channel component | Component events and channel mutations recheck current role, session and ownership; writes hold the authorization lock. |
| Stale channel selection in the setup wizard | Resume and add-address actions refresh the channel used by the form. |

## Migration and validation

Migrations backfill existing customers and history into the default tenant while preserving organization and prospect tokens. Existing staff permissions do not expand automatically. Populated upgrade and rollback tests preserve fourteen tables, relationships, task sharing, foreign keys and deleted-ID high-water marks. SQLite table rebuilds and Turso/Hrana transaction semantics are tested separately; rollback refuses consolidation that would discard tenant-owned data.

Local validation ran on Elixir 1.19.2 / OTP 28 after integrating current main and correcting the review findings. Hosted CI runs on the draft pull request; deployment was not performed.

| Check | Result |
| --- | --- |
| Repository `mix ci` on SQLite | Warnings-as-errors compilation, formatting and strict Credo passed; 2,916 tests, zero failures, 48 skipped |
| Complete suite on actual local libSQL through Turso/Hrana | 2,916 tests, zero failures, 49 skipped; the additional skip is the SQLite-only export test |
| Original audit reproducers | Both passed |
| Populated upgrade and rollback | SQLite, Hrana test server and actual local libSQL preserved fourteen tables, private tokens, relationships, sharing flags and ID high-water marks |
| Production assets and release | Built successfully; release smoke tests passed against disposable SQLite and actual local libSQL databases |
| Security and dependencies | Sobelow completed with no findings under repository configuration; Hex and dependency audits reported no retired packages, advisories or vulnerabilities |
| Browser | Setup discovery and scrolling, intake submission to a private conversation URL, staff label/task creation and live shared-task rendering on the public conversation verified |
| Documentation | 77 local links valid; `git diff --check` clean |

The original audit remains a baseline snapshot with links to this disposition ledger. Temporary verification servers were stopped. Dependency manifests and lockfile were unchanged.

No production credentials, DNS records, forwarding rules or provider resources were changed. Deployment acceptance still requires forwarding from an actual external mailbox, a received reply and a returning reply in the same thread, together with provider signature/delivery evidence. The setup checklist records those observations rather than treating local tests as proof of delivery.
