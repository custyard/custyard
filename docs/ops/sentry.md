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

The DSN's public key is client-embeddable by design, so it is not a secret in
the credential sense. It lives in Fly secrets (not checked-in `fly.toml`) purely
so it stays out of git and can be rotated or disabled without a code change.

## Verifying after deploy

```sh
# emit one test event and confirm it lands in catch.onetimesecret.com/11
fly ssh console -C "/app/bin/custyard rpc 'Sentry.capture_message(\"custyard sentry smoke test\")'"
```

Source-code context is baked into the release image (`mix
sentry.package_source_code` runs in the `Containerfile` before `mix release`),
so stacktraces show source lines.

## What is captured

- **HTTP request exceptions** — `Sentry.PlugCapture` + `Sentry.PlugContext`
  (wired in `CustyardWeb.Endpoint`).
- **Crashed processes and LiveView crashes** — `Sentry.LoggerHandler`, added in
  `Custyard.Application` only when a DSN is configured.

Performance tracing is intentionally **off** (no `traces_sample_rate`): this is
errors-only, and trace spans would capture DB query parameters. Enable later if
wanted.

## What is scrubbed (`Custyard.Sentry`)

All scrubbing is **fail-closed**: if a scrubber raises, the field is replaced
with `[SCRUBBING_FAILED]`, never left intact. Redaction rules live in one place
(`lib/custyard/sentry.ex`) and are wired both into `PlugContext` (`url_scrubber`,
`body_scrubber`) and the global `before_send` callback, so every event is
scrubbed regardless of source.

### HTTP request errors (comprehensive)

This path covers the security-critical auth tokens, which all arrive via
controllers/plugs (not LiveView):

- **Bearer tokens in the URL path** are redacted to `[REDACTED]` — Custyard's
  credentials live in the path, which Sentry's built-in scrubber does *not*
  cover: `/c/:token`, `/claim/:token`, `/operator/login/verify/:token`
  (magic link), `/api/webhook/route/:token` (webhook), `/p/:org_token/...`.
- **Sensitive query params** (`token`, `key`, `secret`, `passphrase`,
  `password`, `callback_token`, `org_token`, `as`) have their values redacted.
- **Request bodies** are dropped entirely — public-intake bodies carry prospect
  PII (name, email, message). Sentry's default header/cookie scrubbers still
  strip `authorization`/`cookie`.
- **Unmatched-route 404s** (`Phoenix.Router.NoRouteError`) are dropped as noise.

### Process / LiveView crash reports (best-effort)

`Sentry.LoggerHandler` reports crashes by `inspect`-ing the crashed process's
state into the event. Custyard's conversation LiveView keeps the raw access
token, the prospect record, and message bodies in socket assigns, so a crash
would otherwise embed them. `before_send` redacts, in the crash message and
`:extra`, the value of any sensitive key — `access_token`, `token`,
`org_token`, `callback_token`, `passphrase`, `secret`, `password`, `email`
(both `key: "..."` and `"key" => "..."` forms, including escaped-quote nesting).
`access_token_hash` is deliberately kept (non-reversible, useful for
correlation). This is verified against a **real** LiveView crash in
`test/custyard_web/sentry_liveview_crash_test.exs`.

> **Residual risk:** key-based redaction cannot catch sensitive data that
> appears *without* a recognizable key — most notably **conversation/message
> body text** embedded in an inspected socket. Treat the Sentry project as
> potentially containing conversation content and restrict access accordingly.
> It is self-hosted on our own EU infrastructure, which bounds the exposure.

Client IP (from `x-forwarded-for`) is retained: it is operationally useful for
abuse triage and the instance is self-hosted in the EU.

Tests: `test/custyard/sentry_test.exs` (redaction rules, the `before_send`
arity-1 contract, the `PlugContext` `url_scrubber` wiring) and
`test/custyard_web/sentry_liveview_crash_test.exs` (a real conversation-LiveView
crash, end-to-end).
