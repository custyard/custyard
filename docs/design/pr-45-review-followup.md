# PR #45 review follow-up

The review inventory covers all conversation comments, formal reviews, and inline threads on [PR #45](https://github.com/custyard/custyard/pull/45), starting at `916d688`. Earlier partial Claude runs describe review limitations; the workflow corrections on main supersede those run failures.

## Confirmed findings

| Feedback | Resolution | Regression coverage |
| --- | --- | --- |
| [Tenant mail fails on SMTP installations](https://github.com/custyard/custyard/pull/45#discussion_r4392284003) | Production enables the Swoosh HTTP client independently of the installation adapter. | Runtime configuration and tenant delivery tests. |
| [New sender reuses old setup checks](https://github.com/custyard/custyard/pull/45#discussion_r4392284017) | Identity changes reset sending and receiving facts and advance a message-ID cutoff. Earlier acceptances, delivery callbacks, and returns cannot restore readiness. | Signed old-message callbacks, returning replies, and a fresh identity round trip. |
| [Revoked administrators can invite staff or change settings](https://github.com/custyard/custyard/pull/45#discussion_r4392284028) | Authorized context operations lock and reload the actor, then validate current role, tenant, and session claim before writing. | Removal, demotion, session rotation, reassignment, and forged role tests. |
| [Duplicate domains make LMTP routing ambiguous](https://github.com/custyard/custyard/pull/45#discussion_r4392297462) | The legacy listener rejects domains matching more than one customer instead of selecting an arbitrary tenant. | Duplicate customer-domain and custom-domain recipients. |
| [Default tenant ignores saved Project token](https://github.com/custyard/custyard/pull/45#discussion_r4392297572) | Receipts, claims, arrival notices, and staff alerts use saved sending credentials while retaining the configured platform identity and recipients. | Saved default-tenant credentials with an SMTP installation and a stub HTTP provider. |
| [Project moves strand tasks in the old organization](https://github.com/custyard/custyard/pull/45#discussion_r4392297651) | A locked transaction moves task ownership with the project. Tasks attached to another customer's conversation prevent the move. | Tasks remain editable after a move; incompatible conversation tasks roll the entire move back. |
| [Tenant-host workspace selection has no effect](https://github.com/custyard/custyard/pull/45#discussion_r4392297723) | Tenant-host navigation explicitly leads instance administrators to the instance console. Workspace selection occurs on that host, where the session selection is effective. | Subdomain/custom-host redirects, no misleading session update, and normal instance-host selection. |
| [Websocket origin validation rejects tenant hosts](https://github.com/custyard/custyard/pull/45#discussion_r4392823770) | The validator accepts configured tenant subdomains and custom domains. Host resolution removes one suffix only. | Configured, unknown, nested, and repeated-suffix origins. |
| [Preflight errors start the provider retry clock](https://github.com/custyard/custyard/pull/45#discussion_r4392824185) | The attempt timestamp starts immediately before a validated provider invocation. Never-attempted failures remain retryable after configuration is repaired. | Old preflight failures can recover; attempted and uncertain deliveries retain their reconciliation limits. |
| [Imported routes lack webhook purposes](https://github.com/custyard/custyard/pull/45#discussion_r4392824491) | Route import initializes missing default consumers idempotently and preserves deliberately disabled consumers. | Import through dispatch creates/enriches the thread and notifies; repeated import preserves disabled choices. |
| [Tenant system mail can have a nil From](https://github.com/custyard/custyard/pull/45#discussion_r4392824807) | A missing selected ingress identity returns `:from_not_set` before mail construction. It does not substitute an unverified public address. | Receipt/claim/notification delivery rejects unavailable ingress identities without calling the provider. |
| [Legacy customer staff lose queue label filters](https://github.com/custyard/custyard/pull/45#discussion_r4392825156) | Label lookup resolves the tenant through the legacy customer assignment and rejects foreign or orphaned scopes. | Legacy administrators and agents can use their workspace labels; foreign and orphaned reads return no labels. |

## Findings not requiring a product change

| Feedback | Disposition and evidence |
| --- | --- |
| [Strip invisible documentation characters](https://github.com/custyard/custyard/pull/45#discussion_r4393118611) | Rejected: these are intentional TextProv attribution marks. The review workflow supplies a readable view and retains exact source attribution. Source marks remain intact. |
| [Project-tenancy rollback may fail](https://github.com/custyard/custyard/pull/45#discussion_r4393295290) | Not reproduced: the populated regression exercises SQLite directly and through the Hrana/Turso driver, preserves seeded project/history data, checks foreign keys, and explicitly asserts that `projects.tenant_id` is removed. The migration disables foreign keys on the connection before its schema transaction. The local Hrana fixture is not a live libSQL engine; the separate sqld CI job validates the real backend suite and fresh migrations. |
| Previously shared tasks appear on the public conversation page | Intentional: only `portal_visible: true` tasks are customer-visible. Existing sharing choices survive migration, new tasks default to private, and the conversation capability token scopes access. Public-page tests cover private tasks, foreign conversations, sharing changes, and revoked tokens. |
| Removed environment-only setup warnings | Intentional: tenant credentials can be stored after startup, so absence of installation credentials does not imply an unconfigured tenant. The setup checklist exposes the tenant's actual missing prerequisites. |
| Instance administrators can open another tenant's project directly | Authorized instance-wide access remains available to super administrators. Tenant staff queries enforce their tenant scope; the project listing applies the selected workspace filter. |
| Attention-queue refresh repeats label/readiness queries | No confirmed defect at this volume. The existing refresh keeps deadlines and setup state current. |

## Thread-level follow-up

- Channel lifecycle transitions now build changesets from the current row, so stale confirmation or revocation cannot preserve newly captured verification data or rotated tokens.
- Lettermint route creation rejects a missing project ID before constructing a provider URL.
- Instance-tenant creation uses the same locked current-role/session authorization principle as staff and settings writes.
- Admin-route tests exercise an actual admin-only route. Connected LiveView tests cover host boundaries, and intake-source tests exercise foreign IDs and forged tenant ownership.
- The setup demotion test asserts a clean redirect and unchanged configuration instead of swallowing arbitrary LiveView exits.

The research audit fixture remains a historical reproducer outside `test/`; it documents the original baseline rather than the current implementation. The implementation ledger and this follow-up describe current behavior. Live external email forwarding and delivery remain separate acceptance checks from the stubbed regressions and CI.

## Local validation

- Full suite: 2,950 tests, zero failures, 48 skipped.
- Warnings-as-errors compilation, strict Credo, Sobelow, Hex audit, and dependency audit pass.
- All 47 workflow guard tests and workflow lint pass.
- Changed Elixir sources match the pinned Elixir 1.18.3 formatter.
- Independent QA found no material functional blocker in the fixes.

The PR checks provide the authoritative pinned OTP/Elixir, real sqld backend, release-smoke, and complete Claude-review results for the pushed head.
