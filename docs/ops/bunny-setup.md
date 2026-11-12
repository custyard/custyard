# Set up Custyard on Bunny

Choose a release image built from a commit containing this portability work.
Earlier published images do not support these Bunny aliases or runtime checks.
After merge, successful main CI publishes the new digest to the GitLab container
registry; use that digest for the acceptance deployment.

Use the published production image with Bunny Magic Containers and Bunny Database.
Start with a disposable database, a temporary hostname and isolated email.
The database driver, environment aliases, origin guard and storage check
are implemented. Live Bunny database and end-to-end deployment acceptance must
still be recorded before moving production traffic or customer data.

Uploaded logos and inbound email attachments are stored in Bunny Database, so
the container needs no persistent volume. A container set up from an earlier
version of this guide, with a `/data` volume, `DATA_VOLUME_ID` and
`bin/data-volume init`, follows
[Upgrade a container that has a file volume](#upgrade-a-container-that-has-a-file-volume).

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
| `STORAGE_PROVIDER` | `bunny`. The app then accepts only the Bunny Database above and expects no volume. |
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

Do not set `DATA_VOLUME_ID`, `UPLOAD_DIR` or `ATTACHMENT_DIR` on a new
container. `DATA_VOLUME_ID` is no longer used; a container that still sets it
boots, with a warning in the boot report that it can be removed. `UPLOAD_DIR`
and `ATTACHMENT_DIR` only tell the app where an earlier release left files.

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

## Create the container

Use [container publishing](container-publishing.md) to select a successful CI image by
digest. The review record [deploy/bunny-production.json](../../deploy/bunny-production.json)
captures all required dashboard settings; it is a local checklist, not a Bunny
API payload. Record the current and candidate digests before promotion.

Configure one region near the database primary, minimum and maximum one replica,
and disable additional regions. Do not attach a persistent volume: the record
has `"persistent_volume": null`. There is no volume to initialize and no
`bin/data-volume` command; the image no longer contains it.

Before it opens the database, boot checks that the database is the configured
Bunny Database. A configuration that selects any other database (a SQLite
file, Turso) stops at the database card "Bunny hosting requires Bunny
Database" instead of creating a SQLite file that would be lost with the
container. For an existing installation, rehearse data transfer and
restoration before starting application writers.

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
app while the existing `custyard` app remains live. Provision the app
explicitly. The file still has a `[mounts]` section for a
`custyard_staging_data` volume at `/data`. With Bunny Database the app does not
need that volume. A staging app that already has logos or attachments on it
keeps the mount until the import reports nothing pending
([Removing the volume](database.md#removing-the-volume)); for a new staging app,
delete the section before the first deploy or provision the volume it names.
Copy [staging.env.example](../../deploy/staging.env.example)
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
that same digest to Bunny. Start a promotion from Build > Pipelines > Run
pipeline on `main` and set `promote_environment` to `staging` or `production`.
The other inputs are the image digest, full source SHA, previous digest and an
HTTPS acceptance-record URL; production requires the last two. Leaving
`promote_environment` at `none` runs the normal CI pipeline instead.

`promote:validate` refuses to run outside a manual pipeline on protected `main`.
It requires a successful push-to-main pipeline for the source SHA in which
`test`, both `turso` providers, `release`, `security` and `publish` passed. The
candidate must exactly match the `published-image.json` record of that
pipeline's latest `publish` job, which binds the repository, image, source SHA,
published digest, pipeline ID and job ID. It then checks the registry
manifest and config against the digest, the source SHA and the
`https://gitlab.com/custyard/custyard` source label. Records expire after 90
days; a missing, expired or invalid record blocks promotion. Retrying `publish`
in a recent pipeline publishes a fresh image and record for the same source
SHA. For expired records, create a new reviewed main commit and take its newly
published digest through staging and acceptance. Images built before the move
to GitLab carry the GitHub source label and cannot be promoted.

Each deploy job repeats these checks on the digest it is about to deploy
rather than trusting the validate job's output. Keep Settings > CI/CD >
Variables > "Minimum role to use pipeline variables" at "No one allowed" (the
project default), so nobody can override inputs or provider settings with
pipeline or manual-job variables.

Staging then deploys automatically: Fly pulls the verified digest straight from
the public GitLab registry. Production waits until a person starts the manual
`promote:production` job; GitLab Free has no deployment approvals, so that click
is the approval, and the job refuses to update Bunny unless it was started by
hand. It checks the current Bunny digest before updating it, confirms the
provider stored the requested digest, and probes HTTPS health. Each environment
is serialized by its own resource group. That health probe establishes service
availability; record which running image was accepted during the real rollout.

Before the first promotion, keep `main` protected and add these CI/CD variables
under Settings > CI/CD > Variables, each scoped to its environment. Mark the
secrets masked and protected so only pipelines on protected branches receive
them:

| Environment | Variables | Masked and protected |
| --- | --- | --- |
| `staging` | `HEALTHCHECK_URL=https://staging.custyard.com/api/health` | `FLY_API_TOKEN` scoped to the staging app |
| `production` | `HEALTHCHECK_URL=https://custyard.com/api/health`, `BUNNY_APP_ID`, `BUNNY_CONTAINER_NAME` | `BUNNYNET_API_KEY` |

Point the Bunny container's registry at `registry.gitlab.com`, image
`custyard/custyard`. The updater changes only the tag and digest; a container
still reading GHCR cannot pull a GitLab-built digest. The project is public, so
the registry and API need no credentials; if it becomes private, add a
`read_api` project access token as `PROMOTION_API_TOKEN` and give Bunny and Fly
registry deploy tokens.

The account API key used by deployment is different from the database access
token. It belongs in the protected CI/CD variable, not the application image.
Production uses a narrow in-repo Bunny image updater derived from the reviewed
provider endpoint. It rechecks the previous digest immediately before the PATCH,
sends only image fields, discards the response body, and prints static errors.
This avoids a vendor-action error path that could log provider response bytes.
See the promotion jobs in [.gitlab-ci.yml](../../.gitlab-ci.yml) and
[the promotion script](../../.gitlab/scripts/promotion.py). Configure runtime
secrets in the provider separately. No pipeline runs a production promotion on
a push. Retain the database backup paired with the previous release. Do
not roll back application code across incompatible schema changes without the
matching recovery procedure.

## Upgrade a container that has a file volume

This applies to a container created from an earlier version of this guide: a
persistent volume at `/data`, initialized with `bin/data-volume init`, with
`DATA_VOLUME_ID`, `UPLOAD_DIR` and `ATTACHMENT_DIR` set.

1. Deploy the new image with the volume still attached and `UPLOAD_DIR` and
   `ATTACHMENT_DIR` unchanged. The `/data/.custyard-volume` marker is no
   longer read, and `DATA_VOLUME_ID` only produces a warning in the boot
   report.
2. Boot copies every logo and attachment that a row refers to from the volume
   into Bunny Database, in the background. Until a file is copied, its logo
   URL and its attachment download answer 404.
3. Check that it finished. From a container shell, which runs as `custyard`:

   ```sh
   /app/bin/custyard eval 'Custyard.Release.import_legacy_files()'
   ```

   `pending 0` means every referenced file is in the database. Without a
   shell, read the container log: one `legacy_file_import_completed` event
   with `missing_files` and `failed_files` both 0 says the same, and a later
   boot that reaches the running app and logs neither that event nor
   `legacy_file_import_failed` had nothing left to import.
4. Remove the persistent volume from the container configuration, then
   remove `DATA_VOLUME_ID`, `UPLOAD_DIR` and `ATTACHMENT_DIR`.

The counts, what `missing` and `failed` mean, and the rollback limits are in
[Upgrading from a release that kept files on disk](database.md#upgrading-from-a-release-that-kept-files-on-disk).
Whether the account offers a container shell has to be checked in the account.

## Back up and restore

File content is in Bunny Database, so the database backup is the whole
backup: there is no separate file snapshot to take or to pair with it. Export
the database with Bunny's tools, retain credential keys separately, and record
the release with the backup identifier. The export is larger than before by
the size of the stored files, which count toward the database's size limit.

`bin/data-volume backup` and `bin/data-volume restore` no longer exist. A
snapshot directory written earlier by `bin/data-volume backup` holds
`uploads/`, `attachments/` and `manifest.json`. No command restores it. To
bring its files into a database whose rows refer to them, copy `uploads/` and
`attachments/` to a location the container can read, point `UPLOAD_DIR` and
`ATTACHMENT_DIR` at those two directories, and let the import above copy them.

After restoring an export into a new database, verify row counts, credential
decryption and the stored files together before admitting writers. The query
in [Checking stored files](database.md#checking-stored-files) lists any file
whose content did not arrive complete, and
`Custyard.Release.import_legacy_files()` prints how many referenced files are
not in the database. Rehearse this with a real export: the file content is
256 KiB blobs, and whether Bunny's export and import carry them intact has
not been recorded.

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
`bin/container-smoke-test custyard:test` with isolated networking and a throwaway
volume. That test exercises the Bunny storage check (it passes with the Bunny
database settings and no volume, and refuses a SQLite database), boot
migrations and first run, origin protection for HTTP/static/
LiveView paths, redirects/HSTS and bounded shutdown. The database used for this
container startup check is SQLite on that volume; live Bunny Database is checked
separately.

Record live Bunny migrations, transactions/savepoints/rollback, stream expiry and
reconnect, cross-connection reads, constraints and binary credentials. Also record
a logo upload and an attachment stored and downloaded through Bunny Database,
blocked origin bypass, HTTPS/Host/cookie behavior,
LiveView, mail send/receive/status/reply, a restored database with its files, and graceful
restart. Keep the historical [migration plan](bunny-production-fly-staging.md)
for cutover/rollback details and [research record](../research/2026-10-29-bunny-migration-validation.md)
for its original evidence. Local or libSQL tests do not substitute for live provider
acceptance.
