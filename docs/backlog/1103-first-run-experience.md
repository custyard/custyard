# First-run experience: safe boot, doctor mode, fewer env vars

Status: approved plan, 2026-11-03. Implementation on branch `feat/boot-doctor`.
Custyard is not in use yet, so the boot path is rewritten in one branch rather
than kept bootable at every step.

## What breaks today

Boot is a straight line that raises at the first problem. Every failure is a
container restart loop whose only output is the log.

```
entrypoint.sh ──► SECRET_KEY_BASE unset?  exit 1
      ▼
bin/custyard eval "migrate(); bootstrap_operator()"      (VM boot #1)
      │  runtime.exs raises on: MAIL_ADAPTER unset/unknown, malformed
      │  CREDENTIAL_ENCRYPTION_KEY, libsql URL without TURSO_AUTH_TOKEN,
      │  relative DATABASE_PATH, ACKNOWLEDGMENTS_* shape
      │  Storage.validate_fly_storage! raises (Fly only)
      │  migrate raises on any database failure
      ▼
exec bin/custyard start                                  (VM boot #2)
      │  runtime.exs evaluated again
      │  Repo child fails ──► supervisor exits ──► restart loop
      ▼
   running
```

The Bunny Magic Containers attempts of 2026-11-02 hit these in sequence, one
redeploy each: `MAIL_ADAPTER` reported unset across edits and restarts (never
explained), quoted values, a 65-byte hex `CREDENTIAL_ENCRYPTION_KEY` with a
trailing newline, a stale `DATABASE_URL` selecting Turso when Turso was not
intended, a platform-named token (`BUNNY_DATABASE_AUTH_TOKEN`) the app does not
read, and a volume that detached during a rollback. On Fly, two machines ended
up with independent SQLite databases and the running one had no operator
accounts; the login page looked healthy because unknown addresses get the same
"check your email" response, and the one real send was a Lettermint 422 whose
reason the logs did not retain.

Variables a production boot needs today:

| Variable | Why | Default today |
|---|---|---|
| `SECRET_KEY_BASE` | sessions | none, boot exits |
| `PHX_HOST` | magic-link URLs | `localhost` (wrong, silent) |
| `MAIL_ADAPTER` + its credential | login links | none, boot raises |
| `OPERATOR_EMAIL` | first account | none, nobody can log in |
| `DATABASE_URL` + `TURSO_AUTH_TOKEN` | remote DB | SQLite at `/data/custyard.db` |
| `CREDENTIAL_ENCRYPTION_KEY` | tenant credentials | none, blocks Email setup |
| `EMAIL_FROM_ADDRESS` | sender | `alerts@custyard.local` (providers reject) |
| `OPERATOR_NOTIFICATION_EMAIL` | alerts | `operator@example.com` |
| `EMAIL_NOTIFICATIONS_ENABLED` | alerts | off |

Dead weight: `BASE_URL` in `fly.toml` is read by nothing; eight `IMAP_*` keys
belong to a removed feature; `LIVE_VIEW_SIGNING_SALT` is already derived.

## Principle

Configuration and database problems are states the app serves, not exceptions
the VM dies on. The HTTP process always comes up. What it serves depends on a
verdict computed once at boot. The page never accepts input and never writes
anything: environment is the configuration, so the fix is always "set these,
restart". This is the Rails pending-migrations page and the Grafana
database-locked page, not the Gitea install wizard.

## Boot state machine

```
                       container start
                              ▼
                 ┌─────────────────────────┐
                 │ Custyard.Boot.Env.read  │  pure; parses env, never raises
                 └────────────┬────────────┘
              required vars missing or malformed?
                   yes        │        no
          ┌───────────────────┴───────────────────┐
          ▼                                       ▼
 ┌─────────────────┐                 ┌─────────────────────────┐
 │ DOCTOR          │                 │ start Repo, probe       │
 │ unconfigured    │                 │ SELECT 1, /data mount   │
 └─────────────────┘                 └───────────┬─────────────┘
                                       fail      │     ok
                             ┌───────────────────┴──────────────────┐
                             ▼                                      ▼
                   ┌─────────────────┐                ┌────────────────────────┐
                   │ DOCTOR          │   re-probe     │ Ecto.Migrator child,   │
                   │ db unavailable  │◄──every 10 s   │ operator bootstrap     │
                   └────────┬────────┘                └───────────┬────────────┘
                            │ 3 consecutive ok              operators who can
                            ▼                               log in == 0 ?
                   System.stop(0); platform            yes   │   no
                   restarts into normal boot    ┌───────────┴───────────┐
                                                ▼                       ▼
                                      ┌─────────────────┐    ┌─────────────────┐
                                      │ FIRST RUN       │    │ READY           │
                                      │ "/" = checklist │    │ normal app      │
                                      │ rest is live    │    └─────────────────┘
                                      └─────────────────┘
```

Supervision tree per verdict:

```
unconfigured / db unavailable          ready / first run
─────────────────────────────          ─────────────────────────
Telemetry                              Telemetry
Endpoint  (BootGate short-circuits)    Repo
Boot.Monitor (db tier only: probes,    {Ecto.Migrator, repos: ...}
  exits 0 after 3 successes)           Boot.FirstRun (operator bootstrap,
                                         welcome mail, progress state)
                                       DNSCluster, PubSub, Finch, RateLimit,
                                       TaskSupervisor, Endpoint, workers
```

| Mode | Browser paths | `/api/health` | `/api/health/live` | Webhooks, LMTP |
|---|---|---|---|---|
| unconfigured | doctor card | 503 `setup_required` | 200 | 503 / not started |
| starting | starting card | 503 `starting` | 200 | 503 / not started |
| db unavailable | doctor card, DB variant | 503 `database_unavailable` | 200 | 503 / not started |
| first run | `/` is the setup card; all else normal | 200 | 200 | normal |
| ready | normal | 200 | 200 | normal |

Implemented 2026-11-03 with one change to the tree above: a configured boot
starts Telemetry and the Endpoint first, in a `starting` mode, and only then
probes the database and runs the migrations synchronously. The remaining
children are added to the running supervisor afterwards. Liveness therefore
answers during a long migration over libSQL HTTP, which would otherwise exceed
a platform's start grace and leave a half-applied schema. The Endpoint starts
before the Repo and PubSub in production; the BootGate blocks everything but
health and static assets until the mode changes, so nothing reaches them early.

Platform health checks (Containerfile `HEALTHCHECK`, `fly.toml`, Bunny) use
`/api/health/live` so the doctor page stays reachable. `/api/health` keeps
readiness semantics for monitoring.

## Mechanics

- Dead views with `<meta http-equiv="refresh">`, not LiveView. LiveView needs
  `check_origin` to agree with `PHX_HOST`, which is one of the things being
  fixed; a failing websocket would be a second trap on top of the first.
- One `CustyardWeb.Plugs.BootGate` at the top of the endpoint, before
  `TenantSession` and `CustomDomain` (both reach the Repo). Doctor modes: card
  for every HTML request, 503 JSON for `/api/*`, health paths pass through.
  First run: only `/` is rewritten.
- Dedicated minimal root layout: no app chrome, no tenant lookup, centered
  card about 40rem wide.
- Doctor mode gives the endpoint a random `secret_key_base`. Nothing is signed.
- Migrations move from the entrypoint eval into `{Ecto.Migrator, repos: ...}`
  as the child after `Repo`, as `mix phx.new` generates. One VM boot instead of
  two; a migration failure becomes a doctor state with the migration name in
  the log.
- `entrypoint.sh` becomes the `MAINTENANCE_MODE` check and `exec`.
- Auto-recovery by exit: `Boot.Monitor` exits 0 after three consecutive
  successful probes; the platform restart policy runs the normal boot. No
  hot-swapping the supervision tree. Migration failure never auto-restarts.
- Same report, two renderers: `Custyard.Boot.Report.to_text/1` prints at boot
  through the privacy logger; the card renders the same struct.
- `bin/operator`, `bin/dsar`, `bin/acknowledgments` print the text report and
  exit 1 unless the verdict is ready.

## Ground truth on every card and in every boot log

The unexplained part of the Bunny story is `MAIL_ADAPTER` staying absent
across edits and restarts. Nothing the app printed could distinguish "not
saved", "applies on redeploy, not restart", or "saved under another name".
Every card and boot log carries:

```
│   Image        custyard 0.9.3 · git 7f3a2c1 · built 2026-11-03 14:02 UTC  │
│   Booted       2026-11-03 21:14:08 UTC                                    │
│   Environment  41 variables visible · 6 of them Custyard settings:        │
│                PHX_HOST  PORT  OPERATOR_EMAIL  SECRET_KEY_BASE            │
│                LETTERMINT_PROJECT_TOKEN  BUNNY_DATABASE_URL               │
│   Near misses  MAIL_ADAPTOR  (did you mean MAIL_ADAPTER)                  │
│   Database     SQLite file /data/custyard.db · /data is a mount ·         │
│                file exists, 41 migrations, 0 operator accounts            │
```

Names only, never values. Image version and git SHA come from build args baked
into the release. The database line states the resolved choice and the reason
("DATABASE_URL is set, so remote"), with file existence, schema version and
operator count, so an empty database on a fresh volume is visible before anyone
tries to log in.

## What the page may reveal

The page is public in the unconfigured state. It shows variable names,
set/missing/malformed, and the shape of a malformed value (surrounding quote
characters, byte length, trailing newline, not Base64). Never values. For the
database tier it shows the category (unreachable, auth rejected, path not
writable, locked, migration failed, volume missing) and which variables to
check; hostnames and raw errors go to the log only. Provider error codes and
messages from the mail check are not personal data and are shown.

## Cards

Unconfigured, zero env vars:

```
┌──────────────────────────────────────────────────────────────┐
│   Custyard is not configured yet                             │
│   This instance started without the settings it needs.       │
│   Nothing has been written. Set these and restart.           │
│                                                              │
│   ✗  SECRET_KEY_BASE    missing   signs sessions and links   │
│   ✗  PHX_HOST           missing   public hostname in emails  │
│   ✗  MAIL_ADAPTER       missing   login links are emailed    │
│   ✓  DATABASE           SQLite at /data/custyard.db          │
│   ⚠  /data              not a mounted volume; data will not  │
│                         survive container removal            │
│                                                              │
│   Copy, replace the ‹…› values, set, restart:                │
│   ┌────────────────────────────────────────────────────────┐ │
│   │ SECRET_KEY_BASE=k9Qf…(generated for this page load)    │ │
│   │ PHX_HOST=‹custyard.example.com›                        │ │
│   │ OPERATOR_EMAIL=‹you@example.com›                       │ │
│   │ MAIL_ADAPTER=lettermint                                │ │
│   │ LETTERMINT_PROJECT_TOKEN=‹project token›               │ │
│   └────────────────────────────────────────────────────────┘ │
│   Other adapters: smtp · postmark · sendgrid · mailgun        │
│   Remote database: DATABASE_URL + TURSO_AUTH_TOKEN           │
│   Fly: fly secrets set KEY=value …   Docker: -e KEY=value    │
│   (image / environment / database lines as above)            │
└──────────────────────────────────────────────────────────────┘
```

Malformed values (the Bunny case). Values are trimmed of whitespace and
newlines; quotes are reported, not stripped, because silent stripping hides
the next problem:

```
│   ⚠  MAIL_ADAPTER       value is wrapped in quote characters │
│                         ("lettermint"). Remove the quotes.    │
│   ⚠  CREDENTIAL_ENCRYPTION_KEY  not Base64 of 32 bytes        │
│                         (65 bytes, trailing newline)          │
│   ⚠  DATABASE_URL       libsql:// but TURSO_AUTH_TOKEN unset  │
```

Database unavailable:

```
┌──────────────────────────────────────────────────────────────┐
│   Custyard cannot reach its database                         │
│   Configuration is complete. The database connection failed, │
│   so the application has not started.                        │
│                                                              │
│   Database       Turso / libSQL over HTTPS                   │
│   Problem        authentication rejected                     │
│   Last attempt   4 s ago · retrying every 10 s · 6 attempts  │
│                                                              │
│   Check                                                      │
│   ·  TURSO_AUTH_TOKEN was created for this database          │
│   ·  DATABASE_URL is the URL from `turso db show --url`      │
│                                                              │
│   When the database answers, Custyard restarts into normal   │
│   mode on its own. The full error is in the container log.   │
└──────────────────────────────────────────────────────────────┘
```

| Category | Detected from | Guidance |
|---|---|---|
| unreachable | DNS / TCP / TLS error | URL host and port, network egress |
| auth rejected | HTTP 401/403 from libSQL | token belongs to this database |
| path not writable | SQLite open error | `DATABASE_PATH`, volume mount, ownership (uid custyard) |
| locked | SQLITE_BUSY after timeout | another process holds the file |
| migration failed | `Ecto.Migrator` error | no auto-restart; log has the migration name |
| volume missing (Fly) | `Storage` mount check | create volume, mount at `/data` |

First run on an empty database, self-refreshing:

```
┌──────────────────────────────────────────────────────────────┐
│   Setting up Custyard                                        │
│   First start on an empty database. What is happening:       │
│                                                              │
│   ✓  Database schema     41 migrations applied in 2.1 s      │
│   ✓  Operator account    you@example.com (super_admin),      │
│                          from OPERATOR_EMAIL                  │
│   ◌  Outbound mail       lettermint · sending welcome mail…   │
│   ○  Sign in                                                 │
└──────────────────────────────────────────────────────────────┘

complete:
│   ✓  Outbound mail       welcome mail accepted by lettermint  │
│   →  Sign in at /operator/login with you@example.com         │
│      After your first login, remove OPERATOR_EMAIL.          │

operator missing:
│   ✗  Operator account    OPERATOR_EMAIL is not set            │
│      Set it and restart, or: docker exec <ctr> bin/operator  │
│      add you@example.com. This page updates when one exists. │

mail failed:
│   ✗  Outbound mail       lettermint rejected the message      │
│                          (422: sender address not verified)   │
│      Login links will fail the same way. Fix the sender, or  │
│      set EMAIL_FROM_ADDRESS, then restart.                   │
```

The welcome mail is the mail check. It goes to `OPERATOR_EMAIL` once, when the
account is created, says the instance is ready and where to sign in, and
carries no login link (links expire in 15 minutes). It exercises the real
adapter, so the unverified-sender 422 shows up here instead of as a login mail
that never arrives. The provider's status and message are logged and shown:
add an allowlisted field for provider error text in the privacy logger.

First run ends when an operator who can log in exists (existing
`OperatorAccounts` predicate: normalized email, not the `admin@custyard.local`
placeholder, not orphaned). The completed card stays on `/` for that boot.

## `bin/doctor` and the database probe

A release overlay like `bin/operator`. Prints the same text report the boot
prints. `bin/doctor --probe-database URL [--token T]` connects, opens a
transaction, runs a throwaway migration up and down against a scratch
database, and reports each step. Run from a laptop against a disposable Bunny
database before any container is deployed. Until it passes, the first verified
install uses SQLite on the volume with zero database variables. That is the
explicit database choice the setup report asked for, made by evidence.

## After login: `/operator/system`

A dead view reusing `Boot.Report` plus the last mail delivery result (adapter,
time, provider status). Makes the install state inspectable later, not only
during boot.

## Reducing the environment

Target for a new install: four variables plus one mail credential.

```
SECRET_KEY_BASE=…
PHX_HOST=custyard.example.com
OPERATOR_EMAIL=you@example.com
MAIL_ADAPTER=lettermint
LETTERMINT_PROJECT_TOKEN=…
```

| Change | Trade-off |
|---|---|
| `EMAIL_FROM_ADDRESS` defaults to `noreply@PHX_HOST`, `EMAIL_FROM_NAME` to `Custyard` | sender still needs provider verification; the card says so |
| `OPERATOR_NOTIFICATION_EMAIL` defaults to `OPERATOR_EMAIL`, then the first super_admin | none |
| `EMAIL_NOTIFICATIONS_ENABLED` defaults on unless `MAIL_ADAPTER=local` | set `false` for silence |
| `CREDENTIAL_ENCRYPTION_KEY` derived from `SECRET_KEY_BASE` (`Plug.Crypto.KeyGenerator`) when unset; explicit value wins; `_PREVIOUS` rotation unchanged | rotating the base secret rotates this key too; same mechanism as the session and LiveView salts; removes the malformed-key failure class |
| `BUNNY_DATABASE_URL` / `BUNNY_DATABASE_AUTH_TOKEN` accepted as fallbacks for `DATABASE_URL` / `TURSO_AUTH_TOKEN` | already proposed in docs/ops/bunny-production-fly-staging.md |
| `PHX_HOST` required in prod; falls back to `FLY_APP_NAME.fly.dev` on Fly | replaces the silent `localhost` default |
| `postgres://` on the SQLite build is a doctor problem ("image built for SQLite/libSQL") | compiled Postgres adapter unchanged |
| Delete `BASE_URL` and `IMAP_*` from `fly.toml`, `LIVE_VIEW_SIGNING_SALT` from the secrets sample | none |

Keep `MAIL_ADAPTER` explicit. Inferring it from which credential is present
saves one variable and adds ambiguity when two are set; the lockout reasoning
in `runtime.exs` is right. The doctor card makes it a one-line fix instead of a
crash, which was the actual pain.

## Code shape

```
lib/custyard/boot/env.ex        %Boot.Env{verdict, problems, warnings,
                                settings, present, near_misses}; pure; the only
                                place variable names are spelled out
lib/custyard/boot/report.ex     to_text/1 for the log; assigns for the card
lib/custyard/boot/monitor.ex    db-tier probe + exit
lib/custyard/boot/first_run.ex  after Ecto.Migrator: bootstrap, welcome mail,
                                progress in :persistent_term
lib/custyard/boot/probe.ex      database probe used by Monitor and bin/doctor
lib/custyard_web/plugs/boot_gate.ex
lib/custyard_web/controllers/boot_controller.ex + boot_html/   dead views
lib/custyard_web/controllers/health_controller.ex              + live/2
config/runtime.exs              calls Boot.Env.read/0; configures what is
                                valid; stores the struct; never raises
lib/custyard/application.ex     children by verdict
lib/custyard/release.ex         with_repo prints the text report, exits 1
                                unless ready; doctor_cli/1
rel/overlays/bin/doctor
entrypoint.sh                   MAINTENANCE_MODE check, then exec
Containerfile                   ARG GIT_SHA, BUILD_TIME into the release
```

Release config providers run with the code path loaded, so `runtime.exs` can
call `Custyard.Boot.Env` as long as it depends on nothing started (stdlib and
`plug_crypto` only). `Custyard.Storage` stops raising and returns problems
that join the same struct.

## Work breakdown

Parallel track A (no dependencies): `/api/health/live`; Containerfile build
args and version reporting; `fly.toml`, `.env.sample`, `.env.secrets.sample`,
`docker-compose.yml` cleanup; `entrypoint.sh` collapse.

Parallel track B: `Boot.Env` with table tests, then `Boot.Report.to_text/1`.

Then, depending on B: `runtime.exs` rewrite, `Application` children by
verdict, `BootGate`, three cards, `Ecto.Migrator` child, `Boot.Monitor` and
`Boot.Probe`, `Boot.FirstRun` and welcome mail, `bin/doctor`,
`/operator/system`, README production section.

## Tests

- `Boot.Env` table tests: every variable across unset, blank, quoted, trailing
  newline, wrong length, wrong encoding, near-miss names.
- `BootGate` controller tests per verdict: card for HTML, 503 JSON for
  `/api/*`, health paths pass through, `/` only in first-run mode.
- `Boot.Monitor` with an injected probe: exits after three successes, never on
  migration failure.
- `FirstRun` through `Swoosh.Adapters.Test`: operator created once, welcome
  mail delivered, provider failure recorded with its message.

## Verified installation path

Run the same list twice, first in Docker on a laptop, then on Bunny. The app
produces the evidence at each step; save the boot and system reports next to
the deployment notes.

```
docker compose up, empty environment      →  doctor card: unconfigured
set the five variables from the card      →  first-run card: schema, operator,
                                             welcome mail accepted (or the 422)
open the welcome mail, sign in            →  dashboard; /operator/system green
mail the support address, reply           →  conversation appears; reply lands
docker compose down && up                 →  normal boot; same operator, same
                                             conversation (persistence proven)
```

On Bunny the first boot additionally confirms `/data` is a mount and survives
undeploy and redeploy.

Out of scope, separate issues: 401 callbacks, reply classification and sender
selection, setup screens not reflecting completed verification.
