# Bunny portability implementation and validation

Implementation branch: `wip/bunny-portability`, based on main `760eeb7`.
Validation date: 2026-11-04. This records repository work and local checks;
live Bunny provider acceptance is a separate release gate.

| Finding | Materiality and consequence | Disposition and evidence | Verification |
| --- | --- | --- | --- |
| BUN-01: database aliases and provider selection | Material: missing or conflicting credentials could select the wrong database. | Addressed in `config/runtime.exs`: explicit provider selection, Bunny aliases, conflict checks, HTTPS and required credentials. | Runtime configuration tests cover missing, blank, conflicting and unsafe values; existing Turso remains supported. |
| BUN-02: v2 transactions and automatic rollback | Material: v3-only status calls prevent Bunny transactions; lost transactions could commit later statements independently. | Addressed in the libSQL protocol/connection modules: v2 endpoint, connection-time interactive probe, conditional pre/post savepoint guards and transaction-control rejection including leading semicolons/BOM. | Driver regressions cover commit, rollback, nested savepoints, ordinary constraint errors, automatic rollback, expiry and reconnect. Full suite passes through v2 against native libSQL. |
| BUN-03: reads across database connections | Material: asynchronous replicas can return stale authentication and permission state. | Addressed with conditional primary transactions for standalone Bunny statements. Keep one nearby database primary during initial rollout. | Local libSQL suite and conditional-batch tests pass; live Bunny routing/consistency still requires provider acceptance. |
| BUN-04: storage checks depended on Fly | Material: an empty replacement volume could silently replace production files. | Addressed with independent storage provider, real mount/identity/directory checks before Repo access, deliberate initialization and interrupted-restore guard. | Mount/identity/ownership/path tests; real image mount/ownership/recovery checks are configured in CI. |
| BUN-05: proxy trust and origin bypass | Material: spoofed visitor headers could affect rate limits or bypass the intended CDN. | Addressed before Phoenix dispatch: Bunny origin authentication, provider-specific IP/scheme handling, preserved Host and secret removal. | HTTP, static, WebSocket and long-poll guard tests; malformed/duplicate headers and the dedicated HTTPS setting are covered. |
| BUN-06: environment selection could reuse production files | Material: staging sync could alter production configuration or leak credentials. | Addressed with explicit three-file selection, target matching before mutation, credential-source checks and a separate staging app/volume. | Fly-task tests cover wrong targets, missing inputs, secret redaction and no mutation on rejection. |
| BUN-07: volume recovery lacked a portable command | Material: files could not be restored safely without Fly SSH conventions. | Addressed with maintenance-only `bin/data-volume`, checked directory snapshots, exact identity, staged restore and static CLI failures. | Backup/restore/corruption/symlink/identity/partial-state tests pass. Provider shell/transfer access and an off-node encrypted recovery rehearsal remain deployment gates. |
| BUN-08: promotion lacked explicit targets and evidence | Material: an unverified or rebuilt image could reach production. | Addressed with manual promotion, digest/config hash verification, an exact published-image record from the successful CI attempt, both CI database lanes, protected environments, previous-digest check and acceptance-record input. Private GHCR images are mirrored to Fly without changing their digest. | Promotion Python tests and actionlint pass; no deployment has been dispatched. HTTPS health proves availability, so running-release identity remains part of live acceptance. |
| BUN-09: new dependency advisory blocked the security gate | Material: current Ecto lock was affected by CVE-2026-118391. | Addressed by upgrading Ecto from 3.14.2 to 3.14.3 and requiring the patched minimum. | Hex and dependency audits pass. |
| BUN-10: vendor updater could print provider response bytes | Material: a parser or transport error could expose returned runtime configuration in CI logs. | Addressed by replacing action execution with a narrow in-repo image PATCH, a fresh previous-digest check, discarded response bodies and static failures. | Promotion tests cover narrow update fields, no mutation on stale digest, discarded bodies and error-output redaction. |
| BUN-11: backup and restore manifest limits diverged | Material: a reported successful snapshot could exceed the restore reader's 16 MiB limit. | Addressed with one shared encoded-size limit checked before creating a snapshot and when reading a manifest. | Boundary regressions cover accepted and rejected sizes; existing round-trip recovery coverage remains. |
| BUN-12: equivalent configured roots bypassed overlap checks | Material: restore could partly fill a shared destination and fail on its second rename. | Addressed by expanding upload and attachment paths before comparing equality or ancestry. | Equivalent and nested alias regressions verify rejection before snapshot or restore-state mutation. |
| BUN-13: promotion trusted image labels without publication evidence | Material: a separate build with matching source labels could pass despite not being the image CI published. | Addressed with an immutable publication artifact bound to the exact successful main CI run and attempt; requested digest and all record fields must match. Missing, expired or invalid records fail closed. | Promotion regressions cover exact matching records, wrong digests and invalid evidence; workflow uploads the record only after publication. |
| BUN-14: publication recovery advice exceeded rerun capabilities | Material: rerunning legacy workflows cannot add the new publisher, and 90-day artifact expiry exceeds GitHub's 30-day rerun window. | Addressed in setup: rerun only eligible recent workflows already containing the publisher; legacy or expired evidence requires a new reviewed main publication and acceptance of its digest. | Checked against GitHub's current rerun documentation and the final publisher/validator flow. |

The setup documentation resolves all fourteen findings and explicitly
states the external acceptance boundary. No finding is silently dropped. The
historical migration document retains its research date and links to the current
[setup instructions](bunny-setup.md).

## Local evidence

- SQLite suite: 3,088 tests, 0 failures, 48 skipped.
- Bunny v2 path against a disposable native libSQL server: 3,088 tests,
  0 failures, 49 skipped. This includes application migrations and the suite's
  migration regression tests; it does not establish managed Bunny behavior.
- Final focused runtime/driver/proxy/recovery/Fly tests: 142 tests, 0 failures.
- Production assets and release built; release startup/operator smoke tests
  passed with SQLite and the existing Turso v3 path.
- Warnings-as-errors compilation, formatting, strict Credo, Sobelow, Hex audit
  and dependency audit passed. Hex emitted a local cache-read warning and
  completed its advisory check; the independent dependency audit also passed.
- Promotion validation tests, actionlint, ShellCheck, shell syntax, Fly TOML
  and Bunny dashboard JSON validation passed.

The local Docker daemon is unavailable. GitHub's Linux container smoke test
[passed for code head 9807317](https://github.com/custyard/custyard/actions/runs/41948625757/job/126986956524),
including volume ownership/identity, backup/restore, startup, origin protection,
HTTPS and shutdown. CI and CodeQL passed for that head. The disposable-database
helper refuses an existing schema before migrations or the suite can run.

PR #65 follow-up validation: 11 file-volume tests and 22 promotion tests passed,
including manifest size boundaries, normalized path aliases, exact CI publication
records, rebuilds, invalid archives and credential-free download redirects.
Compilation with warnings as errors, formatting, strict Credo, actionlint and
whitespace checks passed. The CI record writer produced the expected JSON with
isolated dummy inputs. All 13 local links and code fences in the changed setup
and validation documents passed; the new GitHub rerun reference was checked
separately. The full CI and review gates must pass on the final PR head before
merge.

## Deployment acceptance still required

No customer data or production hosting/DNS was changed. Live managed-Bunny
acceptance checks are disabled at the operator's explicit request. No credentials
are required for the current review. Keep these checks disabled until the
operator explicitly re-enables them. Local libSQL v2 and isolated container CI
remain enabled.

Before a future production promotion, separately arrange managed-database
migrations/transactions/consistency, volume ownership/identity, CDN origin
rejection, Host/TLS/cookies, LiveView, mail roundtrip, running-image identity,
graceful restart and a database/file recovery rehearsal. Configure protected
runtime values and GitHub environments using [setup](bunny-setup.md), and promote
the same accepted digest through staging and production.

Documentation validation covers local file/heading links and balanced fences in
README, the setup guide, this record and the historical migration plan. Newly
referenced Bunny deployment/environment/database/endpoint/header documentation
was read separately. Production examples, account configuration, migration/cutover,
CDN behavior and rendered Markdown were not executed or visually verified.
