# Integrated tenant isolation review

Review date: 2026-10-28. The team reviewed the integrated implementation
before the application database reset. All actionable findings below are resolved. Final validation covers the separate
StaffAccount, Thread and WorkItem mechanical rename commits.

## Ownership and authority

- Installation administrators and tenant staff use separate account stores,
  cookies, signing salts, socket paths and login surfaces. Signed-in chrome
  identifies the realm, actual email and tenant. Email domains grant no access.
- Instance bootstrap requires explicit `INSTANCE_ADMIN_EMAIL`. Tenant staff
  memberships and roles are database records. No default administrator,
  implicit tenant, customer-owned staff or compatibility-only provisioning
  tasks remain.
- Actual HTTP/WebSocket hosts establish tenant authority. The host registry is
  globally unique. Cached session host IDs and LiveView navigation parameters
  never establish a host boundary.
- Staff and instance-admin hooks revalidate current membership, session claims
  and lifecycle status for events, parameter changes, messages and async results.
- Settings, project/customer mutations, attachment access and portal credential
  operations require current staff authority. Writes recheck authority under
  their transaction locks. Local maintenance uses explicit capability types.

## Records, routing and public access

- Tenant IDs are explicit, with composite foreign keys preventing cross-tenant
  customer, contact, project, channel, message, attachment and label links.
  Message/provider deduplication is tenant-local; files have tenant prefixes.
- Global mail ingestion and customer-domain LMTP routing were removed. LMTP
  resolves configured tenant channels. Unconfigured email routes cannot bypass
  channel routing, and internal direct-email adapters cannot authenticate HTTP
  callbacks. Suspended tenants reject new inbound work and retain audit metadata.
- Channel customer/project/label values are hints. Known sender identity and
  existing threads retain precedence. Ambiguous sender relationships remain
  unassigned. A project hint must agree with the customer.
- Public thread, portal and claim lookups are tenant-bound and check active
  lifecycle state. Mounted prospect sessions revalidate the live credential's
  hash and revocation state before every callback. Portal revocation reloads
  the credential by persisted ID and scoped tenant before changing it.
- Acknowledgment subscriptions, encrypted broker credentials, bindings and
  operations belong to tenants. Staff operations require Scope; local release
  commands use an explicit tenant capability rather than ambient actor strings.

## Erasure and retained evidence

- Exports recheck current staff authority. Erasure locks and rechecks authority
  inside the write transaction, including revocation and suspension races.
- Personal customer email identities and display names are anonymized; linked
  prospect identities and credentials are scrubbed/revoked. Pending claims are
  released; provisioned slug labels retain their registry entry without personal
  email or confirmation tokens. Contact-attributed portal credentials are revoked.
- Matching tenant/customer audit sender/subject fields and unassigned rejection
  identities are scrubbed. New generic webhook audits omit raw sender and subject.
  Operational identifiers, actor metadata and other tenants remain intact.
- Immutable acknowledgment evidence retains its existing evidence policy and
  prevents ordinary customer deletion. Customer deletion otherwise removes its
  customer graph while retaining tenant infrastructure and audit history.

## Threading and deployed safeguards

The production changes through `origin/main` at `1566e28` were reconciled with
the ownership refactor: independent sending domains, public receiving Reply-To,
late Proton forwarding confirmations, project-scoped status webhook validation,
and persisted setup progress all remain covered.

Lettermint's `X-LM-Preserve-Message-ID` control is applied before delivery
fingerprinting. Message-ID, Reply-To, reviewed recipients and envelope headers
remain immutable across retries. Archive copies remain own echoes. The live
pilot handoff is evidence for the deployed revision, separate from validation
of this branch; no pilot records were deleted during implementation.

Existing-thread-first header matching was reviewed and retained deliberately.
An unambiguous in-tenant reference supports multiparty participants, including
people known to another customer. Adding a participant grants no portal
credential. Invalid references do not match; ambiguous references create a fresh
sender-associated thread. Cross-tenant references never match.

## Installation homepage and workspace hostname correction

The initial cutover incorrectly registered the installation hostname to the
pilot tenant. That allowed tenant branding and staff sign-in on Custyard's own
homepage. The user clarified that the installation and tenant sites must be
distinct, including for a single pilot tenant.

The configured installation hostname is now reserved by tenant-host validation,
HTTP routing and shared host resolution used by WebSocket authentication.
Stale database mappings cannot establish tenant authority or generate tenant
URLs on that hostname. Tenant hosts reject installation administration routes.
The installation homepage presents Custyard, with a workspace-slug finder and
separate installation administrator entry. The finder resolves an active,
registered workspace hostname on the server and redirects to its staff login.
Tenant homepages retain their workspace branding. Root layouts use verified
host ownership for branding; repeated document titles were removed.

The independent integrated review found no unresolved issues. The final full
CI run, including broker tests, passed 2,638 tests with zero failures or skips;
formatting, compilation and strict Credo pass. Production assets, release build
and disposable-database release smoke pass. Staff login and customer receipt
links use the registered tenant hostname.

## IMAP lifecycle follow-up

The final job review found that a suspended tenant could still establish an
IMAP session or advance its mailbox cursor before dispatch rejected a message.
The separate lifecycle fix resolves persisted channel/tenant authority before
network access, rechecks suspension during the session and before writes, and
blocks UID/error-counter changes while suspended. Tenant lifecycle events stop
or restart pollers immediately.

A further independent review found that an unlinked session could outlive its
poller and keep fetching the remaining batch. Sessions now monitor their caller,
cancel the worker on caller termination, and bound connection cleanup. Every
message rechecks persisted authority before fetching and before dispatch. The
real Plover connection links and socket ownership were reviewed for acquisition
races. Focused coverage passes 36 tests, including suspension during fetch,
caller termination, isolated worker crashes, unchanged cursor/counters and
resumption. The integrated follow-up review found no remaining actionable gaps.

## Validation and reset gate

Required gates are compilation with warnings as errors, formatting, strict
Credo, the complete test suite including local RabbitMQ integrations, asset
build, and clean diff checks. Mechanical renames remain separate commits and
receive the same final checks. The application database reset follows these
gates; the live pilot database is outside the local reset target.

Final checks on 2026-10-28:

- `ACKNOWLEDGMENTS_TEST_AMQP_URL=amqp://guest:guest@127.0.0.1:5672 MIX_TEST_PARTITION=_ci_installation_host3 mix ci`: **2,638 tests, zero failures, zero skipped**, with compile warnings treated as errors, formatter and strict Credo passing.
- `mix assets.build`: passed.
- `MIX_ENV=prod mix release --overwrite`: passed.
- `bin/release-smoke-test`: passed against a temporary local SQLite database and local mail capture. Verified migration, explicit instance-admin bootstrap, CLI add/list/remove beside the running server, and health before/after provisioning.
- `git diff --check`: passed.

The user selected the live pilot database as the reset target. Its SQLite file
was reset on 2026-10-28 after the full checks and independent review passed,
a consistent backup passed integrity checks, and a volume snapshot completed.
The fresh baseline has one explicitly provisioned installation administrator
and one OneTimeSecret tenant; customer, thread and message tables are empty.
See [the cutover record](../ops/tenant-baseline-cutover.md) for deployment evidence.
No Git push was performed by this task. The provider round trip after fresh
tenant email configuration remains separate from local checks and the earlier
release-82 pilot handoff.
