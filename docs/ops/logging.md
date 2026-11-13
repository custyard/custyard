# Application logging policy

Status: engineering baseline for general compliance readiness. This is not a certification or a claim that deployment controls have been verified. The [readiness ledger](../audits/application-logging-2026-10-31.md) records evidence and outstanding operational controls.

## Scope and purpose

Operational logs explain application activity, security-relevant decisions, and failures. Persisted audit events preserve the identity, time and outcome of selected business actions. They have different storage and retention requirements. Explicit operator CLI output and data-subject exports are authorized administrative responses; treat their terminal recordings and exported files as sensitive, and do not forward them wholesale into a log collector.

The baseline follows [OWASP logging guidance](https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html): record actionable events and correlation, exclude secrets and unnecessary personal data, prevent injection, verify failure behavior, and protect collection, access and retention. The privacy objective is to collect only diagnostics necessary for these purposes. Deployment owners must also evaluate their applicable legal, contractual and customer requirements.

## Enforced event contract

Use `require Custyard.Log, as: Log` and a registered literal event atom:

```elixir
Log.warning(:outbound_delivery_failed,
  [message_id: message.id, tenant_id: tenant.id] ++ Log.failure(reason)
)
```

An event name is a stable machine identifier. New names must be registered in `Custyard.Log`; a dynamic or unregistered event is a compile error. Direct application `Logger` calls, Logger imports/aliases, and runtime `IO`/debug output are rejected by a source-level regression test. Another source gate verifies declared literal metadata and registered manual Sentry message names; domain-catalog checks cover webhook purposes and acknowledgment/broker failure reasons. The explicit release CLI output modules and the boot report module `Custyard.Boot.Console` are reviewed exceptions; the console prints only `Custyard.Boot.Report` text, which lists variable names, problem kinds, counts, the image build and the database kind, never values. Migration diagnostics use the same event API. Do not interpolate values into event names or use an event field to carry arbitrary text.

The shared boundary admits only declared fields and their types:

| Field family | Accepted values |
| --- | --- |
| Internal entity IDs | Nonnegative integers for declared staff, tenant, organization, channel, route, thread, message and other database identifiers |
| Correlation | Bounded server-generated request/operation IDs; an operation may retain its parent operation ID |
| Counts and timing | Declared nonnegative counts, byte sizes, retry values and elapsed milliseconds |
| Categories | Explicit finite values for reason, outcome, stage, mode, provider, `boot_mode`, `database_category`, first-run `step` and related classifications |
| Provider diagnostics | Numeric HTTP status, an allowlisted machine error code, and a bounded list of allowlisted validation-field names |
| Bounded provider messages | `provider_message`, carried only by the declared events that emit it (`boot_welcome_mail_failed`): valid UTF-8 only, control and format characters replaced by spaces, every whitespace-delimited token containing `@` or `://` replaced by `[redacted]`, cut to 200 characters; empty or non-string input is omitted |
| External references | SHA-256 reference of a bounded opaque external identifier when correlation requires it; never the identifier itself |
| Code identity | Loaded code module/function/arity; Sentry may retain numeric code lines; never arguments, local variables, source context or exception text |

Unknown keys and unsupported values are omitted. Every admitted categorical value must survive repeated sanitization; exhaustive round-trip and actual JSON-output tests enforce this invariant. Expanding the schema requires reviewing purpose, privacy, cardinality, size and retention implications. Identifiers and hashes remain restricted, potentially personal or linkable data; they are not declared anonymous.

Do not log addresses, names, subjects, customer content, sender/recipient envelopes, credentials, token prefixes, signed attachment URLs, request/response bodies, headers, cookies, arbitrary hostnames/IPs, raw protocol commands, or rendered exception/changeset/stacktrace data. These exclusions apply at debug level too.

## Output and enforcement

`Custyard.Log.install!/0` installs a primary Erlang Logger filter before application children or release-time repositories start. The filter applies before all handlers, including Sentry. It rebuilds messages and metadata from the approved contract. Unstructured dependency, OTP and framework messages become `external_log`, retaining severity and safe diagnostic/code identity. Their original text, format arguments, process state and report callbacks are not sent to handlers. A filter/formatter failure emits the fixed `log_event_rejected` record rather than the original value. The fixed Sentry domain is retained to prevent SDK errors from reporting themselves recursively.

When a default console handler is present, its formatter emits one JSON record per line with an ISO 8601 UTC timestamp, severity, stable event, service `custyard`, schema version and approved fields. This changes the previous human-readable output: collectors and saved searches must query the JSON `event`, `request_id`, `operation_id` and identifier fields. A temporary debug-level increase does not restore discarded data. Add a reviewed structured diagnostic when more detail is needed.

Production application logs default to info. Expected activity and skipped/accepted outcomes use info; rejected work and recoverable degraded operation generally use warning; failed persistence, crashed work and internal failures use error. The existing login-provider terminal outcomes remain info so the original lifecycle contract remains stable. Alerts should select event/outcome and rate, rather than assuming every provider rejection is an application crash.

## Request, job and protocol correlation

HTTP correlation uses a fresh server-generated ID returned as `x-request-id`. Incoming values are not copied into operational metadata because they are arbitrary client text. Request summaries contain only method, fixed route class, status and duration. Magic-link and other bearer-token paths remain excluded from request summaries. Token consumption emits `operator_login_succeeded` or `operator_login_rejected` without the token or URL. Logout emits `operator_logout`; its optional `session_operator_id` is the identity snapshot from the signed session, rather than a fresh account validation. Unknown paths are classified as `other`; the raw URL and query are omitted.

Use `Log.task/2` when starting asynchronous work. It captures only approved parent context, creates a new operation ID in the child, and restores worker metadata even on failure. Use `Log.operation/2` for scheduled work and durable delivery attempts. Durable retries correlate through database message/channel/tenant IDs and their new operation ID; an originating request is not claimed unless it is actually retained. LMTP transaction IDs reset between messages and after RSET. Connection/message telemetry excludes envelopes, peer addresses, commands and raw error contents.

SQL query logging and sensitive connection-error output are disabled. Phoenix parameter logging uses an empty keep-list. Third-party telemetry such as raw Repo, Phoenix or Swoosh events may contain application data: no generic metadata-forwarding exporter is authorized by this policy. Export approved operational events or define an independently reviewed metric schema.

## Provider and exception diagnostics

`Log.failure/1` accepts HTTP errors, Lettermint management wrappers, known transport categories, changeset failures and exception classes. It does not render their contents. Provider machine codes must exactly match the reviewed allowlist. Validation fields are reduced to reviewed provider and application-schema field-name labels, including labels for credential fields; validation messages, credentials, addresses and submitted values are discarded. A provider offering only free-form prose will still yield a status and generic classification. Adding a new safe category requires an exact mapping and a hostile-echo regression test, never a broad response-body exception.

DBConnection failures remain `external_log` records, with `stage: connect` or `stage: disconnect`, an exception class when recognized, and the same finite `database_category` used by boot diagnostics. Failed connections use the structured `crash_reason` metadata. DBConnection 2.10 disconnects provide no structured exception, so the filter recognizes only that dependency's known chardata/banner shape and classifies at most 16 KiB of exception text. The text, driver identity, PID/label, SQL and credentials are discarded before handlers run. Unknown or malformed banners yield an unknown category; an unrecognized message shape retains only the usual external-log fields. Changes to DBConnection's logging format require updating the real connection/disconnect regression tests, not forwarding its raw message.

Boot diagnostics follow the same rule. `boot_database_probe_failed` carries a finite `database_category`, the attempt count and the exception class from `Log.failure/1`; the probe classifies the driver error and never logs its text, host, token or path. `boot_welcome_mail_failed` carries the provider, the numeric provider status and the sanitised `provider_message`, because the reason a sender was rejected is operational, not personal. The raw probe error appears only in `bin/doctor` terminal output, which is administrative CLI output of the same class as `bin/instance-admin`: treat its recordings as sensitive and do not forward them into a log collector.

[Sentry](sentry.md) independently rebuilds every exported event. It retains approved correlation, static events, loaded exception classes and minimized code frames, and drops customer-bearing event compartments. This covers manual events as well as Logger and HTTP capture. Manual operational message captures use registered event names and approved context so their category and request correlation survive minimization. Deployment environment labels must be registered in `:log_environments`; unreviewed labels fall back to the application environment.

## Persisted audit records and erasure

`AuditEvent.Payload` applies per-event typed allowlists. New payloads omit duplicate addresses, names, subjects, raw provider reasons and undeclared nested values. Actor identity uses internal IDs and roles. Necessary external reference columns, verified domain targets and contractual acknowledgment source/submission identifiers and evidence digests remain restricted audit evidence. Their presence is not permission to publish an audit export as operational logging.

Audit records are read in the application through `Custyard.AuditLog` only. A tenant admin reads the events of their own tenant at `/app/settings/audit`; agents cannot. An instance admin reads installation events and instance-admin actions on a tenant at `/admin/audit`, and never an event of a tenant's own work. Both views pass each stored payload through its allowlist again before display, so a record written before minimization shows no address or message text, and neither view shows RFC Message-IDs, acknowledgment identities or digests.

An explicit organization-scoped data-subject erasure also minimizes historical customer-bearing audit fields transactionally. It preserves event identity/time, unrelated actors and other organizations, and records the redacted event IDs/count in a new erasure event. It does not silently delete acknowledgment evidence or operator-action history. There is no mass historical rewrite or automatic new audit-deletion period in this change.

## Deployment controls and acceptance evidence

The service owner must record the following for each log destination, including console collection, Sentry, audit storage, exports and backups. Do not mark deployment readiness complete until these records have been verified.

| Control | Required evidence |
| --- | --- |
| Retention and deletion | Named purpose, approved duration, collector/database expiry configuration, export/backup treatment and a demonstrated expiry/deletion test |
| Access | Named owner, least-privilege reader/admin groups, strong authentication, periodic access review and recorded access/export activity |
| Integrity and transport | Authenticated encrypted shipping, protected destination/storage, restricted deletion and demonstrated investigation of logging failures |
| Export and incident handling | Redaction/review procedure, permitted recipients, storage/expiry of extracts, and response to previously leaked tokens or personal data |
| Data handling | Destination, region, subprocessors/agreements where applicable, and handling of subject requests and legal holds |
| Monitoring | Alert routing for error events, `log_event_rejected`, collection outages, repeated external/provider failures, and a periodic collection self-test |

Retention durations are a service-owner decision tied to purpose and obligations; this code does not invent a universal compliant duration or destroy historical logs. Conversation retention settings do not imply retention for Sentry, operational logs or standalone audit records. Previously collected data is not retroactively cleaned by the new filter.

After deployment, verify the actual running revision and JSON records in each collector. Exercise a test staff login and an unknown-account request through the browser, matching the returned request ID to the safe lifecycle in `fly logs --app custyard`. Confirm expected timestamp/service/schema, destination delivery, and access restricted to approved readers.

With the required release configuration present, the built release can also emit a harmless self-test in an isolated eval VM:

```sh
bin/custyard eval 'Application.ensure_all_started(:logger); Custyard.Log.install!(); require Custyard.Log; Custyard.Log.info(:logging_self_test, outcome: :succeeded); Logger.flush()'
```

This checks the packaged formatter and stdout in that VM. Deployment uses Erlang distribution disabled, so `rpc` is unavailable. SSH command output may be returned only to the terminal; use the running application HTTP flow to verify console collection and the [Sentry smoke command](sentry.md#verifying-after-deploy) to verify Sentry. Run destructive/hostile canary cases in the test environment, not against production customer data. Record observations, destination settings and approved retention/access decisions in the readiness ledger.

## Change and regression gate

Run the full test suite, warnings-as-errors compilation, formatting and strict Credo for changes to logging. Focused tests cover hostile provider echoes, list-valued JSON metadata, arbitrary Logger/OTP report contents, malformed UTF-8, request-ID injection, real LiveView crashes, task/LMTP context reset, Sentry grouping and complete-event minimization, typed audit records and scoped historical erasure. The release smoke test covers commands that load the application without starting its supervision tree, including a fresh repository-only VM, safe failure text, nonzero migration and rollback exit status, and `bin/doctor` in every boot mode. Unit tests preserve the running Logger process and its filters; inspecting Mix task execution must use read-only state rather than executing `app.start`. Startup never raises on configuration: `config/runtime.exs` records the `Custyard.Boot.Env` verdict and the application boots into a doctor mode that serves a value-free card. The boot report and the cards name variables and problem kinds without values; the hostile-value canary test in `test/custyard/boot/report_test.exs` proves no configured value reaches the report text or the paste block.

Any new handler, exporter, telemetry integration, event field, provider mapping or Sentry SDK field requires the same privacy review and real output-boundary tests. The fixed event catalog and source guard make accidental bypasses visible during development.
