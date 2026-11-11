# docs/ops/sentry.md
---

Error tracking for Custyard reports to the **self-hosted Sentry instance in the
EU**: `catch.onetimesecret.com`, project `11`.

## Enabling it

Sentry is **prod-only and off unless a DSN is set** (`config/runtime.exs` reads
`SENTRY_DSN` only when `config_env() == :prod`; with no DSN the SDK records
nothing). `config/test.exs` also pins `dsn: nil` so the test suite can never
reach the live instance.

Set the DSN as a Fly secret (triggers a restart):

```sh
fly secrets set SENTRY_DSN="https://639217059887a4ea497a0b34a646e1a0@catch.onetimesecret.com/11"

# optional
fly secrets set SENTRY_ENVIRONMENT="custyard-eu-prod"   # default: "production"
fly secrets set SENTRY_RELEASE="$(git rev-parse --short HEAD)"
```

`SENTRY_ENVIRONMENT` is retained only when it matches a reviewed label in
`config :custyard, :log_environments`: `dev`, `test`, `prod`, `development`,
`production`, `staging` or `custyard-eu-prod`. An unknown or malformed value
falls back to the application's `dev`/`test`/`prod` environment. Add deployment
labels to that allowlist through a reviewed configuration change.

The DSN's public key is client-embeddable by design, so it is not a secret in
the credential sense. It lives in Fly secrets (not checked-in `fly.toml`) purely
so it stays out of git and can be rotated or disabled without a code change.

## Verifying after deploy

```sh
# emit one test event and confirm it lands in catch.onetimesecret.com/11
fly ssh console -a custyard -C "/app/bin/custyard eval 'Application.ensure_all_started(:sentry); IO.inspect(Sentry.capture_message(\"logging_self_test\", result: :sync))'"
```

Erlang distribution is off, so `bin/custyard rpc` does not work. The `eval`
above starts a separate VM with the production configuration (including
`SENTRY_DSN`) and only the Sentry client, not the app; it prints `{:ok, id}`
when the event was accepted.

The smoke event uses a registered static event name. A successful result proves
that the error tracker accepted the event; check the project for
`logging_self_test` to verify its arrival.

Source-code packaging still runs when the release is built, but the send boundary
omits source snippets and local variables. Reports retain approved exception
classes and code locations rather than captured request or process contents.

## What is captured

- **HTTP request exceptions** — `Sentry.PlugCapture` + `Sentry.PlugContext`
  (wired in `CustyardWeb.Endpoint`).
- **Crashed processes, LiveView crashes, and error-level operational events** —
  `Sentry.LoggerHandler`, added in `Custyard.Application` only when a DSN is
  configured. It receives already-minimized Logger events.

Performance tracing is intentionally **off** (no `traces_sample_rate`): this is
errors-only, and trace spans would capture DB query parameters. Enable later if
wanted.

## Privacy boundary (`Custyard.Sentry`)

The application-wide [logging policy](logging.md) applies to console output and
Sentry. `Custyard.Log` installs a primary Logger filter before application
children and the Sentry handler start. Application events use registered static
names and typed metadata. Arbitrary OTP, dependency, and crash-report messages
become an `external_log` event with approved code identity and classifications;
rendered arguments and process state do not reach log handlers.

`Sentry.LoggerHandler` captures error-level minimized messages as well as
exceptions. This preserves reporting after the raw OTP crash shape has been
removed. Its metadata includes approved request and operation identifiers.
The fixed `:sentry` domain marker survives the filter so an SDK transport error
cannot recursively report itself.

Every outbound error event then passes through `Custyard.Sentry.before_send/1`.
The callback constructs a fresh event from an allowlist instead of copying
compartments and searching them for recognizable secrets. This also protects
manual capture calls and HTTP exceptions that did not originate in Logger.

### Retained diagnostics

- SDK-generated event identifier and timestamp, a bounded release identifier,
  severity, and the reviewed deployment environment.
- Loaded exception class, bounded stack frames, and approved module/function/
  line information. Frame filenames come from compiled code, not event text.
- Registered static event name and approved code origin, including the nested
  Logger metadata shape used by the Sentry SDK. These participate in a rebuilt
  grouping fingerprint so independent error sites remain distinguishable.
- Operational IDs, counters, finite failure classifications, numeric provider
  status, and other fields admitted by `Custyard.Log.sanitize_metadata/1`.
- A known HTTP method and a fixed route template. Request hosts, arbitrary
  path segments, query names and query values are omitted. Bearer-token routes
  contain `[REDACTED]`; unknown routes become `/[OTHER]`.

Internal account, tenant and request identifiers remain linkable operational
data. Their inclusion requires the access and retention controls in the logging
policy; minimization does not make the records anonymous.

### Omitted data

- Rendered exception text and arbitrary message/interpolation contents. An
  unregistered message becomes `application_error`.
- Request data, all headers, cookies, environment values and query strings;
  customer IP addresses and user profiles are not retained.
- Arbitrary extras, tags, contexts, breadcrumbs, caller-provided fingerprints,
  transactions and culprit strings.
- Socket/process state, stack-frame arguments and variables, source snippets,
  mechanism data, thread names/state/locks and attachments.
- Private SDK fields such as the original exception and integration metadata.

Unmatched-route 404s (`Phoenix.Router.NoRouteError`) remain excluded as noise.
Unexpected callback values are dropped. If minimization raises, the callback
returns a new `sentry_scrubbing_failed` event with none of the original event's
compartments, rather than attempting to reuse a partially scrubbed event.

The earlier URL/text redaction helpers remain useful when constructing
`PlugContext`; they are not the final privacy guarantee. The complete send
boundary also removes unlabelled personal data that a key-based regex cannot
recognize.

### Validation and operating controls

`test/custyard/sentry_logger_handler_config_test.exs` registers the real SDK handler using the exact application options and verifies capture settings and unchanged primary Logger configuration with DSN nil.

`test/custyard/sentry_test.exs` covers every event compartment, nested Logger
metadata with atom/string keys, spoofed code identity, malformed interfaces,
invalid UTF-8, size bounds, distinct grouping and failure fallback.
`test/custyard_web/sentry_liveview_crash_test.exs` crashes a real thread
LiveView and checks the complete event received by a Logger handler, then the
minimized Sentry event, for both the access token and unlabelled customer content.

This boundary governs newly emitted events. Previously collected Sentry data
may still contain information retained by earlier versions. Review existing
records and apply the approved retention/erasure policy through the Sentry
operator controls. Do not treat the self-hosted EU location as a substitute for
restricted access, retention configuration or evidence that those controls work.
