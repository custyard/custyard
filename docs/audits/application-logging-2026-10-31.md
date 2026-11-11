# Application logging readiness ledger — 2026-10-31

Scope: general engineering compliance-readiness baseline requested after the operator-login logging fix. Starting revision: `d8f154a`. The existing local `fly.toml` edit is unrelated and excluded. No production database, retention setting, account permission or deployment is changed by this work.

The audit inventoried 156 Logger call sites/examples across 44 application files, plus framework/dependency output, Sentry event compartments, asynchronous execution, release-only commands and persisted audit records. The table records disposition; implementation completion and operational verification are separate states.

| ID | Finding | Disposition and evidence |
| --- | --- | --- |
| L01 | Token-prefix and full token-path diagnostics bypassed request suppression | Addressed: static webhook/custom-domain events; no token prefixes or raw path; bearer-path request summaries stay suppressed |
| L02 | MIME, LMTP, notifications and operator logs exposed addresses/content/protocol input | Addressed: all application Logger calls migrated to the registered event API; debug-level privacy and LMTP/MIME/notification regressions |
| L03 | Raw exception/report/SQL values could reach console and handlers | Addressed: global pre-handler filter, fail-closed JSON formatter, query/parameter exclusions, arbitrary-report and actual-crash tests |
| L04 | Useful IDs and diagnostic classifications disappeared through formatter whitelist | Addressed: declared typed fields survive the canonical JSON formatter, including message/tenant IDs, provider code/status and validation-field names; actual handler regression |
| L05 | Provider errors exposed too little safe diagnostic detail | Addressed: shared HTTP/management/transport classifier, finite code/field mappings; raw provider prose and echoes remain excluded |
| L06 | Tasks, scheduled work, durable mail and LMTP transactions lacked consistent correlation | Addressed: safe context capture, fresh scoped operation IDs, internal entity correlation and metadata restoration/reset tests |
| L07 | Sentry left unprocessed payload compartments and could leak arbitrary content | Addressed: complete allowlist reconstruction, minimal code identity and static-event grouping; full-event hostile canaries and real crash regression |
| L08 | Sanitizing Logger reports could suppress Sentry capture or cause SDK loops | Addressed: safe error-message capture enabled, fixed Sentry domain preserved, static event/origin retained and grouping tested |
| L09 | Audit payloads duplicated customer/operator addresses, subjects and raw provider reasons | Addressed: event-specific typed payload schemas and minimized builders; necessary external evidence remains explicit and access-restricted |
| L10 | Explicit subject erasure left historical customer audit content behind | Addressed: transactional organization-scoped historical redaction with changed-event evidence; unrelated identity/tenant/acknowledgment preservation tested |
| L11 | Release commands load the application without starting the privacy boundary | Addressed: install before release-time storage/Repo work; app-unstarted release smoke coverage |
| L12 | Logging policy, severity/schema rules and safe extension path were undocumented | Addressed: [application policy](../ops/logging.md), Sentry documentation, source bypass guard and explicit operational acceptance requirements |
| L13 | Token-bearing authentication routes lacked session outcome events | Addressed: static login succeeded/rejected and logout events, request correlation, finite rejection reasons, signed-session identity distinguished from validated account ID; successful, replayed, expired, malformed and orphaned-account regressions |
| L14 | Release/configuration exceptions could bypass Logger through eval stderr | Addressed: fixed startup messages, finite filesystem causes, sanitized migration/rollback/bootstrap failures with nonzero exits, actual release canary checks; explicit administrative exports remain sensitive responses |
| L15 | Exception diagnostics could overwrite LMTP retry category in stop telemetry | Addressed: preserve the documented temporary/permanent category after merging safe failure fields; exception-reason regression confirms the category and excludes private exception text |
| L16 | Fixed caller categories and known changeset labels could disappear at the privacy boundary | Addressed: canonical intake reasons and registered/correlated manual Sentry messages; complete acknowledgment/broker failure and webhook-purpose catalogs; known provider/parser/catch wrappers; reviewed schema field-name labels without values. Domain-catalog and literal-metadata source gates prevent drift. Broker retries retain safe cause/outcome/delay without URI or password. Final inventory checked 183 log/context calls across 45 files, including 27 derived metadata expressions. |
| L17 | A pre-existing Mix test restarted Logger while checking whether app.start had run | Addressed: read execution markers without running app.start, restore original task/alias markers, and assert Logger PID and primary filters remain unchanged. The restart had restored Logger’s pre-application config and erased the filter; handler/crash regressions correctly detected it. Release installation is now tested in a fresh VM instead of temporarily removing the shared test filter. No production filter-reinstallation workaround. |
| L18 | String error-type categories were dropped on the second sanitization pass | Addressed: canonical enum fallback after the exception-class check, plus exhaustive idempotence and actual JSON-output coverage for every admitted enum value; no values or new categories admitted |
| R01 | Review suggested Sentry capture_level/capture_metadata were unsupported | Rejected against locked Sentry 14 source: these are the dedicated capture options (older level/metadata are aliases). Shared unchanged application options now have an actual SDK handler-registration test verifying capture level/metadata/tags, enabled ErrorBackend and unchanged primary configuration, with DSN nil. |
| O01 | Running deployment and end-to-end collector behavior | Operational verification pending: record running revision, actual safe login/self-test records, destination delivery and outage behavior after deployment |
| O02 | Collector/Sentry/audit/export/backup retention and deletion | Owner decision and verification pending: approved durations, configured expiry, legal-hold exceptions and demonstrated deletion; no destructive defaults introduced |
| O03 | Access, authentication, export monitoring and integrity | Operational verification pending: reader/admin groups, owner, access review, strong authentication, encrypted shipping/storage and access/export evidence |
| O04 | Existing historical logs and provider/dependency telemetry exporters | Operational review pending: assess old collected payloads and any active generic exporter; new filtering does not retroactively remove prior data |
| D01 | Locked dependencies reported pre-existing security advisories during validation | Addressed: targeted compatible updates `phoenix_html 4.3.0 → 4.4.0` and `ssl_verify_fun 1.1.7 → 1.1.9`; Phoenix.HTML minimum raised to 4.4. Final Hex and Mix dependency audits pass. Advisories: EEF-CVE-2026-117645 and EEF-CVE-2026-117666. |

## Validation evidence

- Final `MIX_ENV=test mix ci`: warnings-as-errors compilation, formatting, strict Credo, and **3,030 tests, 0 failures, 48 skipped**. Skipped integration cases require external services; GitHub CI supplies RabbitMQ and libSQL for those jobs.
- Production release build and final SQLite release smoke passed, including actual eval nonzero failures, safe stderr and canary absence, operator provisioning and continued HTTP health.
- `mix sobelow --exit`, `mix hex.audit`, `mix deps.audit`, `git diff --check`, and `bash -n bin/release-smoke-test` passed.
- Final independent reviews covered runtime/HTTP/Sentry, typed audit payloads, scoped erasure, and release startup/failure paths; all actionable findings were resolved.
- Remote head `e4d46e6` passed main/RabbitMQ and Turso tests, release (SQLite/libSQL), security, container, and CodeQL jobs. Initial head `89871d7` passed Turso, release (SQLite/libSQL), security, container, and CodeQL jobs. Its test job stopped at an Elixir 1.18/1.19 formatting difference, corrected with an explicit function body. Automated static review completed 95/95 files and identified the LMTP category issue above; the correction passed the full local suite. A second complete static review found the intake omission that prompted L16 and the full catalog inventory. Final source checksums remained fixed throughout the successful local pass. Current-head remote status is available on PR #62.
- Turso run on `e13e25b` exposed the Mix helper’s Logger reset above. The corrected helper passed the failing seed `546689` with the real handler/crash cases (20 tests, 0 failures, 2 external-service skips), then the full 3,028-test local checks. Fresh-VM repository boot, migration/rollback/bootstrap privacy and release health smoke passed.
- Remote head `b390211` passed main/RabbitMQ, Turso, release, security and container jobs after the Logger test-isolation correction. Later review identified L18 and raised R01 above; both now have empirical coverage and the final full local pass is 3,030 tests. Current-head checks remain separately visible in PR #62.
- Production runtime/collector settings: not inspected or modified by this implementation.
- The original login PR's historical tests or CI are not substituted for this branch's checks.

## Operational decision record

Complete these fields with the service owner before calling a deployment compliance-ready:

- Responsible service/security owner and review date: pending.
- Runtime collector destination, region, reader/admin groups and retention: pending.
- Sentry destination, region, reader/admin groups and retention: pending.
- Audit-evidence retention, purpose, legal-hold and explicit erasure policy: pending.
- Export/backup expiry, access/export activity evidence and deletion test: pending.
- Running revision and safe event samples/self-test destination evidence: pending.
- Alert routing and collector-outage/lost-event response test: pending.

## Evidence references

- [Phoenix.HTML security changelog](https://phoenix-html.hexdocs.pm/changelog.html) and [ssl_verify_fun advisory](https://github.com/deadtrickster/ssl_verify_fun.erl/security/advisories/GHSA-7gw2-hphm-c5px): compatible security patch evidence.

- [OWASP Logging Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html): event purpose, minimization, injection resistance, verification, access/integrity and retention controls.
- [Erlang Logger filters](https://www.erlang.org/doc/apps/kernel/logger_filters.html): primary filtering applies before handler-specific processing.
- [Lettermint Sending API](https://lettermint.co/docs/api-reference/sending/send): provider response/validation interface. Response messages and body values are not approved log fields.
- Repository policy and acceptance instructions: [Application logging](../ops/logging.md), [Sentry](../ops/sentry.md).
