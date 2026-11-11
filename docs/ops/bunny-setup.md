# Set up Custyard on Bunny

Choose a release image built from a commit containing this portability work.
Earlier published images do not support these Bunny aliases or runtime checks.
After merge, successful main CI publishes the new digest through the existing
GHCR workflow; use that digest for the acceptance deployment.

Use the GHCR production image with Bunny Magic Containers and Bunny Database.
Start with a disposable database, a temporary hostname and isolated email.
The database driver, environment aliases, origin guard and volume validation
are implemented. Live Bunny database and end-to-end deployment acceptance must
still be recorded before moving production traffic or customer data.

## Configure the application

Add these values to the container's runtime environment. Keep secrets in Bunny's
protected settings. Runtime values are read when the release boots; changing
them requires a new deployment. See Bunny's [deployment guide](https://bunny.net/docs/magic-containers/deploy)
and [environment configuration](https://bunny.net/docs/magic-containers/environment-variables).

| Variable | Value |
| --- | --- |
| `PHX_HOST` | Temporary test hostname; `custyard.com` only at cutover. No URL scheme. |
| `PORT` | `4000` |
| `DATABASE_PROVIDER` | `bunny` |
| `BUNNY_DATABASE_URL` | Database URL from Bunny's Access page, using `https://` or `libsql://`. |
| `BUNNY_DATABASE_AUTH_TOKEN` | Database full-access token for writes and migrations; not the account API key. |
| `STORAGE_PROVIDER` | `bunny` |
| `DATA_VOLUME_ID` | A stable identity such as `custyard-prod-files-v1`, preserved in the volume marker. |
| `UPLOAD_DIR` | `/data/uploads` |
| `ATTACHMENT_DIR` | `/data/attachments` |
| `PROXY_PROVIDER` | `bunny` |
| `BUNNY_ORIGIN_SECRET` | At least 32 bytes; generate with `openssl rand -hex 32`. Configure the matching CDN request header below. |
| `SECRET_KEY_BASE` | Persistent secret, generated with `openssl rand -hex 64`. |
| `CREDENTIAL_ENCRYPTION_KEY` | Base64 of exactly 32 bytes: `openssl rand -base64 32`. |
| `MAIL_ADAPTER` | `lettermint` with working installation mail. |
| `LETTERMINT_PROJECT_TOKEN` | Sending token from the isolated test project initially. |
| `EMAIL_FROM_ADDRESS` | Sender on a verified Lettermint domain. |
| `INSTANCE_ADMIN_EMAIL` | First instance administrator's address; remove after initial setup. |
| Acknowledgments | No environment switch. Each tenant enables its own integration in Settings, so a new installation consumes nothing; use a dedicated broker/source for acceptance. |
| `LMTP_ENABLED` | `false` for webhook-based email. |
| `EMAIL_NOTIFICATIONS_ENABLED` | `false` during initial acceptance. Login mail and replies still send. |

Optional: `SENTRY_DSN`,
`SENTRY_ENVIRONMENT=production`, and `SENTRY_RELEASE` set to the deployed SHA.
Tenant administrators configure encrypted mail credentials and signed webhook
bindings in [Email setup](lettermint-email-setup.md). Keep the legacy global
`IMAP_ENABLED` unset. Session and LiveView salts derive from `SECRET_KEY_BASE`;
explicit overrides remain supported. Preserve production encryption/session
keys when migrating existing records; staging must use independent keys/data.

### Database aliases and protocol

Bunny's [database integration](https://bunny.net/docs/database/connect/magic-containers)
can populate `BUNNY_DATABASE_URL` and `BUNNY_DATABASE_AUTH_TOKEN` automatically.
Either alias selects Bunny when `DATABASE_PROVIDER` is unset. Explicit
`DATABASE_PROVIDER=bunny` prevents a missing configuration from initializing
a local SQLite database. Missing URL/token or conflicting provider settings
keep the app from starting: `config/runtime.exs` never raises, so the container
stays up, the boot report in its log (and `bin/doctor`) names the variable, and
the server shows that report in place of the app. `DATABASE_URL` and `TURSO_AUTH_TOKEN` remain accepted with explicit
Bunny selection; if both naming schemes are supplied their values must match.
Use a database base URL or its `/v2/pipeline` URL; a conflicting pipeline
version, plaintext Bunny URL or credentials in the URL are rejected.

The Bunny path uses `/v2/pipeline`. Connecting verifies a transaction can span
multiple requests with a baton and then roll back. If the account lacks
interactive-session support, the boot probe reports the database as unavailable
instead of running migrations against an unverified transaction implementation. Bunny's [SQL API documentation](https://bunny.net/docs/database/connect/sql-api)
asks interactive-session users to contact Bunny; arrange support if needed.

Standalone statements use conditional BEGIN/statement/COMMIT batches, routing
reads to the primary across pooled connections. Explicit transactions use a
reserved savepoint to detect automatic rollback without v3's `get_autocommit`.
Use Ecto's transaction APIs; raw BEGIN/COMMIT/ROLLBACK/SAVEPOINT SQL through
ordinary query calls is rejected. Lost or expired sessions fail the operation;
the driver does not retry writes whose outcome is unknown. Existing Turso
configuration retains its v3 behavior.

## Create the container and volume

Use [GHCR publishing](ghcr-publishing.md) to select a successful CI image by
digest. The review record [deploy/bunny-production.json](../../deploy/bunny-production.json)
captures all required dashboard settings; it is a local checklist, not a Bunny
API payload. Record the current and candidate digests before promotion.

Configure one region near the database primary, minimum and maximum one replica,
and disable additional regions. Mount the intended persistent volume at `/data`.
The mount must be writable by the image's `custyard` user; mounting a volume hides
the ownership baked into the image. Check ownership with the actual container.

For a new empty volume, boot in `MAINTENANCE_MODE=true`, which starts neither
migrations nor the server. Using the provider's container shell or a deliberately
configured maintenance container sharing the volume, run as `custyard`:

```sh
/app/bin/data-volume init
```

This deliberately creates `/data/.custyard-volume` with `DATA_VOLUME_ID` and the
upload/attachment directories. It refuses an unmarked nonempty volume, wrong
identity, symlinked paths or an unmounted `/data`. Normal boot only validates an
existing marker and directories; it never adopts an empty replacement volume.
Remove `MAINTENANCE_MODE` after initialization. For an existing installation,
rehearse data transfer and restoration before starting application writers.

Configure HTTP startup/readiness checks on port `4000`, exact path
`/api/health/live`. Liveness answers as soon as the server listens, so a
container that is still migrating, or that is reporting a configuration or
database problem instead of running the app, is not restarted in a loop.
`/api/health` is readiness: 200 only once the app is running, 503 otherwise. Use
it for monitoring and for the promotion `HEALTHCHECK_URL`, not for the platform
checks. A passing health check does not prove email delivery. Verify graceful SIGTERM handling during the acceptance deploy.

## Configure the CDN endpoint

Create a [CDN endpoint](https://bunny.net/docs/magic-containers/endpoints) for
container port `4000`. Leave **SSL for origin** off because the app serves HTTP
internally. TLS terminates at Bunny's edge.

- Enable **Forward Host Header** so tenant and custom-domain routing receive the
  visitor's Host. Custyard does not trust `X-Forwarded-Host`.
- Add a **Set Request Header** edge rule that overwrites `X-Custyard-Origin`
  with the exact protected `BUNNY_ORIGIN_SECRET`. Apply it to every app path,
  including WebSocket and long-poll requests. Custyard removes this header before
  Phoenix dispatch and error reporting. Missing/wrong values return 403 before
  redirects, static files, sockets or application routes. Only GET/HEAD of exact
  `/api/health` or `/api/health/live` with no query bypasses this guard for
  provider probes. With `BUNNY_ORIGIN_SECRET` missing or shorter than 32 bytes
  every other request is refused, including the page that reports configuration
  problems; read the boot report in the container log or run `bin/doctor`.
- Start with **Override Cache Time = 0**, disable Perma-Cache, and purge existing
  cached responses. Keep HTML, login links, APIs, webhook paths, private attachments
  and LiveView out of shared cache. Consider fingerprinted `/assets/*` only after
  validation with two separate authenticated sessions.
- Enable WebSockets in the endpoint's Pull Zone. Preserve cookies, authorization,
  request bodies, query strings and HMAC headers. Verify an actual LiveView upgrade,
  live updates, uploads, idle connection and reconnect after a restart.
- Keep credential-bearing URLs out of edge logs/forwarders. If redaction is
  unavailable, disable optional logging and confirm unavoidable retention/access.

Bunny replaces `X-Forwarded-For` with one visitor address and supplies
`X-Forwarded-Proto`; see its [origin header reference](https://bunny.net/docs/cdn/request-headers-to-origin).
Custyard ignores `Fly-Client-IP` and `X-Forwarded-Port` on this path. HTTP and
LiveView rate limits use the same validated visitor address. Test that direct
origin requests fail and forged client headers cannot override the CDN values.
Attach the intended custom hostname and issue its certificate before switching
DNS; follow the [migration sequence](bunny-production-fly-staging.md#3-rehearse-the-transfer-and-dns-setup)
to preserve mail records and replace both old A and AAAA routes.

## Keep staging separate and promote a verified image

[fly.staging.toml](../../fly.staging.toml) targets a separate `custyard-staging`
app and its own volume while the existing `custyard` app remains live. Provision
the app/volume explicitly. Copy [staging.env.example](../../deploy/staging.env.example)
and [staging.secrets.example](../../deploy/staging.secrets.example) into protected,
ignored local files, fill in staging credentials, and preview with explicit inputs:

```sh
mix fly.secrets --config fly.staging.toml --env-file .env.staging --secrets-file .env.staging.secrets --app custyard-staging
```

Add `--apply` only after reviewing the preview. All three source/config options
are required together, and `--app` must match the selected TOML before any file
or remote mutation. Staging uses `STORAGE_PROVIDER=fly`, `PROXY_PROVIDER=fly`
and `DATABASE_PROVIDER=bunny`; these choices are independent.

Run acceptance against the candidate digest in staging, then deliberately promote
that same digest to Bunny using the manual **Promote image** workflow. It accepts
the target environment, image digest, full source SHA, previous digest and an
HTTPS acceptance-record URL. Production requires the last two fields. The
workflow serializes each environment, verifies registry metadata against the
digest and source SHA, and requires successful main CI including both database
providers and publication. The candidate must exactly match the immutable
`published-image-RUN_ID-RUN_ATTEMPT` artifact from that successful CI attempt.
Its `published-image.json` record binds the repository, image, source SHA and
published digest. Records expire after 90 days; a missing, expired or invalid
record blocks promotion. A recent run that already contains this publisher can
be rerun in full within [GitHub's 30-day rerun window](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs)
to publish a fresh image and record. Reruns retain the original workflow and
source SHA. For legacy workflows or expired records, create a new reviewed main
commit and take its newly published digest through staging and acceptance.
It checks the current Bunny digest before updating it, confirms the provider
stored the requested digest, and probes HTTPS health. That health probe
establishes service availability; record which running image was accepted
during the real rollout.

Before dispatch, create GitHub environments `staging` and `production`, restrict
them to `main` (or protected branches with main protected), and configure required
reviewers for production. Set these environment values:

| Environment | Variables | Secrets |
| --- | --- | --- |
| `staging` | `HEALTHCHECK_URL=https://staging.custyard.com/api/health` | `FLY_API_TOKEN` scoped to the staging app |
| `production` | `HEALTHCHECK_URL=https://custyard.com/api/health`, `BUNNY_APP_ID`, `BUNNY_CONTAINER_NAME` | `BUNNYNET_API_KEY` |

The account API key used by deployment is different from the database access
token. It belongs in the protected GitHub environment, not the application image.
Production uses a narrow in-repo Bunny image updater derived from the reviewed
provider endpoint. It rechecks the previous digest immediately before the PATCH,
sends only image fields, discards the response body, and prints static errors.
This avoids a vendor-action error path that could log provider response bytes.
See [the workflow](../../.github/workflows/promote.yml). Configure runtime secrets
in the provider separately. No workflow runs a production promotion on a push.
Staging mirrors the verified private GHCR image into Fly's registry while
preserving its digest, then deploys that digest. Retain the database/file backup
paired with the previous release. Do not roll back application code across
incompatible schema changes without the matching recovery procedure.

## Back up and restore files

Stop application writers and boot with `MAINTENANCE_MODE=true`. Mount a separate
backup location outside `/data`, writable by `custyard`, then run:

```sh
/app/bin/data-volume backup /backup/custyard-snapshot
```

The new directory contains uploads, attachments and a SHA-256 manifest with volume
identity, file paths, sizes and hashes. Both backup and restore support a maximum
16 MiB manifest; backup rejects a larger manifest before creating the snapshot.
Upload and attachment directories must remain separate after path expansion.
The snapshot is not encrypted: transfer it securely
off-node and encrypt it with the deployment's backup tooling. Bunny volume storage
is not an independent backup. Export the database separately with Bunny's tools,
retain credential keys separately, and record the same release/backup identifier.

To restore, initialize an empty mounted volume with the intended `DATA_VOLUME_ID`,
securely copy the snapshot to the external backup mount, and run while stopped:

```sh
/app/bin/data-volume restore /backup/custyard-snapshot
```

Restoration verifies identity and checksums, rejects symlinks/special files and
nonempty target directories, and stages files before moving them into place.
An interrupted restore leaves `.custyard-restore-in-progress`; boot refuses to
start. Inspect the staged/partially moved files, preserve the snapshot, and clean
the partial target only after deciding how to retry. Do not remove the guard and
start a partially restored installation. Verify database row counts, files and
credential decryption together before removing maintenance mode.

## Acceptance evidence

Live managed-Bunny acceptance checks are disabled by operator decision. Keep
those checks disabled until explicitly re-enabled; credentials are not needed
for the current review. Local libSQL v2 and isolated container CI remain enabled.

Use the [Bunny database check](../../bin/bunny-database-check) only against a new,
empty, disposable test database. It refuses an existing application schema and
requires an explicit disposable-test opt-in. It runs migrations and the test
suite through the Bunny v2 path; it never proves production data was restored.

Set `BUNNY_TEST_DATABASE_URL` and `BUNNY_TEST_DATABASE_AUTH_TOKEN` from the
disposable database's protected credentials, then run:

```sh
BUNNY_TEST_DISPOSABLE=true bin/bunny-database-check
```

CI runs the full suite against a real libSQL server in both v3 and Bunny v2 modes.
Its container job builds and loads the image, then runs
`bin/container-smoke-test custyard:test` with isolated networking and throwaway
volumes. That test exercises Linux mount/ownership checks, marker rejection,
file backup/restore, boot migrations and first run, origin protection for HTTP/static/
LiveView paths, redirects/HSTS and bounded shutdown. The database used for this
container startup check is SQLite; live Bunny Database is checked separately.

Record live Bunny migrations, transactions/savepoints/rollback, stream expiry and
reconnect, cross-connection reads, constraints and binary credentials. Also record
the actual volume owner/identity, blocked origin bypass, HTTPS/Host/cookie behavior,
LiveView, mail send/receive/status/reply, restored files/database, and graceful
restart. Keep the historical [migration plan](bunny-production-fly-staging.md)
for cutover/rollback details and [research record](../research/2026-10-29-bunny-migration-validation.md)
for its original evidence. Local or libSQL tests do not substitute for live provider
acceptance.
