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
or restart pollers immediately.

A󠄁 f󠄁u󠄁r󠄁t󠄁h󠄁e󠄁r󠄁 i󠄁n󠄁d󠄁e󠄁p󠄁e󠄁n󠄁d󠄁e󠄁n󠄁t󠄁 r󠄁e󠄁v󠄁i󠄁e󠄁w󠄁 f󠄁o󠄁u󠄁n󠄁d󠄁 t󠄁h󠄁a󠄁t󠄁 a󠄁n󠄁 u󠄁n󠄁l󠄁i󠄁n󠄁k󠄁e󠄁d󠄁 s󠄁e󠄁s󠄁s󠄁i󠄁o󠄁n󠄁 c󠄁o󠄁u󠄁l󠄁d󠄁 o󠄁u󠄁t󠄁l󠄁i󠄁v󠄁e󠄁 i󠄁t󠄁s󠄁
p󠄁o󠄁l󠄁l󠄁e󠄁r󠄁 a󠄁n󠄁d󠄁 k󠄁e󠄁e󠄁p󠄁 f󠄁e󠄁t󠄁c󠄁h󠄁i󠄁n󠄁g󠄁 t󠄁h󠄁e󠄁 r󠄁e󠄁m󠄁a󠄁i󠄁n󠄁i󠄁n󠄁g󠄁 b󠄁a󠄁t󠄁c󠄁h󠄁.󠄁 S󠄁e󠄁s󠄁s󠄁i󠄁o󠄁n󠄁s󠄁 n󠄁o󠄁w󠄁 m󠄁o󠄁n󠄁i󠄁t󠄁o󠄁r󠄁 t󠄁h󠄁e󠄁i󠄁r󠄁 c󠄁a󠄁l󠄁l󠄁e󠄁r󠄁,󠄁
c󠄁a󠄁n󠄁c󠄁e󠄁l󠄁 t󠄁h󠄁e󠄁 w󠄁o󠄁r󠄁k󠄁e󠄁r󠄁 o󠄁n󠄁 c󠄁a󠄁l󠄁l󠄁e󠄁r󠄁 t󠄁e󠄁r󠄁m󠄁i󠄁n󠄁a󠄁t󠄁i󠄁o󠄁n󠄁,󠄁 a󠄁n󠄁d󠄁 b󠄁o󠄁u󠄁n󠄁d󠄁 c󠄁o󠄁n󠄁n󠄁e󠄁c󠄁t󠄁i󠄁o󠄁n󠄁 c󠄁l󠄁e󠄁a󠄁n󠄁u󠄁p󠄁.󠄁 E󠄁v󠄁e󠄁r󠄁y󠄁
m󠄁e󠄁s󠄁s󠄁a󠄁g󠄁e󠄁 r󠄁e󠄁c󠄁h󠄁e󠄁c󠄁k󠄁s󠄁 p󠄁e󠄁r󠄁s󠄁i󠄁s󠄁t󠄁e󠄁d󠄁 a󠄁u󠄁t󠄁h󠄁o󠄁r󠄁i󠄁t󠄁y󠄁 b󠄁e󠄁f󠄁o󠄁r󠄁e󠄁 f󠄁e󠄁t󠄁c󠄁h󠄁i󠄁n󠄁g󠄁 a󠄁n󠄁d󠄁 b󠄁e󠄁f󠄁o󠄁r󠄁e󠄁 d󠄁i󠄁s󠄁p󠄁a󠄁t󠄁c󠄁h󠄁.󠄁 T󠄁h󠄁e󠄁
r󠄁e󠄁a󠄁l󠄁 P󠄁l󠄁o󠄁v󠄁e󠄁r󠄁 c󠄁o󠄁n󠄁n󠄁e󠄁c󠄁t󠄁i󠄁o󠄁n󠄁 l󠄁i󠄁n󠄁k󠄁s󠄁 a󠄁n󠄁d󠄁 s󠄁o󠄁c󠄁k󠄁e󠄁t󠄁 o󠄁w󠄁n󠄁e󠄁r󠄁s󠄁h󠄁i󠄁p󠄁 w󠄁e󠄁r󠄁e󠄁 r󠄁e󠄁v󠄁i󠄁e󠄁w󠄁e󠄁d󠄁 f󠄁o󠄁r󠄁 a󠄁c󠄁q󠄁u󠄁i󠄁s󠄁i󠄁t󠄁i󠄁o󠄁n󠄁
r󠄁a󠄁c󠄁e󠄁s󠄁.󠄁 F󠄁o󠄁c󠄁u󠄁s󠄁e󠄁d󠄁 c󠄁o󠄁v󠄁e󠄁r󠄁a󠄁g󠄁e󠄁 p󠄁a󠄁s󠄁s󠄁e󠄁s󠄁 3󠄁6󠄁 t󠄁e󠄁s󠄁t󠄁s󠄁,󠄁 i󠄁n󠄁c󠄁l󠄁u󠄁d󠄁i󠄁n󠄁g󠄁 s󠄁u󠄁s󠄁p󠄁e󠄁n󠄁s󠄁i󠄁o󠄁n󠄁 d󠄁u󠄁r󠄁i󠄁n󠄁g󠄁 f󠄁e󠄁t󠄁c󠄁h󠄁,󠄁
c󠄁a󠄁l󠄁l󠄁e󠄁r󠄁 t󠄁e󠄁r󠄁m󠄁i󠄁n󠄁a󠄁t󠄁i󠄁o󠄁n󠄁,󠄁 i󠄁s󠄁o󠄁l󠄁a󠄁t󠄁e󠄁d󠄁 w󠄁o󠄁r󠄁k󠄁e󠄁r󠄁 c󠄁r󠄁a󠄁s󠄁h󠄁e󠄁s󠄁,󠄁 u󠄁n󠄁c󠄁h󠄁a󠄁n󠄁g󠄁e󠄁d󠄁 c󠄁u󠄁r󠄁s󠄁o󠄁r󠄁/󠄁c󠄁o󠄁u󠄁n󠄁t󠄁e󠄁r󠄁s󠄁 a󠄁n󠄁d󠄁
r󠄁e󠄁s󠄁u󠄁m󠄁p󠄁t󠄁i󠄁o󠄁n󠄁.󠄁 T󠄁h󠄁e󠄁 i󠄁n󠄁t󠄁e󠄁g󠄁r󠄁a󠄁t󠄁e󠄁d󠄁 f󠄁o󠄁l󠄁l󠄁o󠄁w󠄁-󠄁u󠄁p󠄁 r󠄁e󠄁v󠄁i󠄁e󠄁w󠄁 f󠄁o󠄁u󠄁n󠄁d󠄁 n󠄁o󠄁 r󠄁e󠄁m󠄁a󠄁i󠄁n󠄁i󠄁n󠄁g󠄁 a󠄁c󠄁t󠄁i󠄁o󠄁n󠄁a󠄁b󠄁l󠄁e󠄁 g󠄁a󠄁p󠄁s󠄁.󠄁

## Validation and reset gate

Required gates are compilation with warnings as errors, formatting, strict
Credo, the complete test suite including local RabbitMQ integrations, asset
build, and clean diff checks. Mechanical renames remain separate commits and
receive the same final checks. The application database reset follows these
gates; the live pilot database is outside the local reset target.

Final checks on 2026-10-28:

- `ACKNOWLEDGMENTS_TEST_AMQP_URL=amqp://guest:guest@127.0.0.1:5672 MIX_TEST_PARTITION=_ci_session_final2 mix ci`:󠄁 **2󠄁,󠄁6󠄁3󠄁0󠄁 tests, zero failures, zero skipped**, with compile warnings treated as errors, formatter and strict Credo passing.
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
