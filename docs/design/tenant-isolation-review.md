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

## IMAP lifecycle follow-up

The final job review found that a suspended tenant could still establish an
IMAP session or advance its mailbox cursor before dispatch rejected a message.
The separate lifecycle fix resolves persisted channel/tenant authority before
network access, rechecks suspension during the session and before writes, and
blocks UID/error-counter changes while suspended. Tenant lifecycle events stop
or restart pollers immediately. Focused coverage passes 33 tests, including
stale input, suspension during login, unchanged cursor/counters and resumption.

## Validation and reset gate

Required gates are compilation with warnings as errors, formatting, strict
Credo, the complete test suite including local RabbitMQ integrations, asset
build, and clean diff checks. Mechanical renames remain separate commits and
receive the same final checks. The application database reset follows these
gates; the live pilot database is outside the local reset target.

Final checks on 2026-10-28:

- `ACKNOWLEDGMENTS_TEST_AMQP_URL=amqp://guest:guest@127.0.0.1:5672 MIX_TEST_PARTITION=_ci_final_names mix ci`: **2,627 tests, zero failures, zero skipped**, with compile warnings treated as errors, formatter and strict Credo passing.
- `mix assets.build`: passed.
- `MIX_ENV=prod mix release --overwrite`: passed.
- `bin/release-smoke-test`: passed against a temporary local SQLite database and local mail capture. Verified migration, explicit instance-admin bootstrap, CLI add/list/remove beside the running server, and health before/after provisioning.
- `git diff --check`: passed.

No application or pilot database reset has been executed. The reset target is
pending selection; no remote deployment or Git push was performed by this task.
The live provider round trip after deployment remains separate from these local
checks and from the earlier release-82 pilot handoff.
