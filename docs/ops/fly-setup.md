# Set up Custyard on Fly

Run the published image on the Fly app `custyard` ([fly.toml](../../fly.toml))
with its database on [Turso](https://turso.tech). Logos and attachments are
stored in the database, so the app needs no volume. An app that still keeps
its SQLite file on a `/data` volume follows
[Move an existing app to Turso](#move-an-existing-app-to-turso).

[Fly.io deployment](../flyio-deployment.md) is the full reference: commands,
instance administrators, data subject requests, troubleshooting.

## Configure the application

Non-secret values go in `fly.toml` `[env]`, secrets in `fly secrets`.
`mix fly.secrets --apply` syncs `.env.secrets` and skips commented lines;
check `fly secrets list`, not the file.

| Variable | Value |
| --- | --- |
| `PHX_HOST` | `[env]`. Hostname without scheme. Unset on Fly, it falls back to `<app>.fly.dev` with a warning. |
| `PORT` | `[env]`, `4000`. Must match `internal_port`. |
| `DATABASE_PROVIDER` | `turso`. A missing or non-`libsql://` `DATABASE_URL` then stops boot at the doctor card instead of opening a SQLite file. |
| `DATABASE_URL` | Secret. `libsql://<db>-<org>.turso.io`. An `https://` URL is rejected. |
| `TURSO_AUTH_TOKEN` | Secret. `turso db tokens create <db>`. |
| `SECRET_KEY_BASE` | Secret, at least 64 bytes: `openssl rand -base64 64`. Keep it stable; changing it ends every session. |
| `CREDENTIAL_ENCRYPTION_KEY` | Secret, Base64 of exactly 32 bytes: `openssl rand -base64 32`. Keep production's value when moving data. |
| `MAIL_ADAPTER` | `lettermint` (in `[env]`). Required: login is magic-link only. |
| `LETTERMINT_PROJECT_TOKEN` | Secret. |
| `EMAIL_FROM_ADDRESS` | `[env]`. Sender on a verified Lettermint domain. |
| `INSTANCE_ADMIN_EMAIL` | Secret. First instance administrator; unset after the first login. |
| `LMTP_ENABLED` | `false`. Fly blocks the ports. |
| `CLAMAV_HOST` | `custyard-scanner.flycast`, the separate scanner app ([fly.scanner.toml](../../fly.scanner.toml), [setup](../../ops/clamav/README.md)). Fly Proxy starts it on demand; `.internal` cannot wake it. Unset, attachments stay quarantined. |

`STORAGE_PROVIDER` and `PROXY_PROVIDER` default to `fly` when `FLY_APP_NAME`
is set; leave them unset. With Turso the storage check verifies nothing: no
mount, no machine count. The `fly` proxy setting takes the client address
from `Fly-Client-IP` and never trusts `X-Forwarded-Host`.

Do not set `BUNNY_DATABASE_URL` or `BUNNY_DATABASE_AUTH_TOKEN`: either one
conflicts with `DATABASE_PROVIDER=turso` and stops boot. On a new app, do not
set `DATA_VOLUME_ID`, `UPLOAD_DIR`, `ATTACHMENT_DIR`, `DATABASE_PATH` or
`IMAP_ENABLED`.

Optional: `SENTRY_DSN`, `SENTRY_ENVIRONMENT` (default `production`),
`SENTRY_RELEASE` set to the deployed SHA, `EMAIL_NOTIFICATIONS_ENABLED=false`
during acceptance, `POOL_SIZE` (default 10).

## Create the app

1. Create the database in a Turso group located near `primary_region`
   (`ams`). Each statement is an HTTPS round trip. A database's location is
   its group's; `turso group list` shows them.

   ```sh
   turso group create <group> --location <nearest to ams>
   turso db create custyard --group <group>
   turso db show custyard --url
   turso db tokens create custyard
   ```

2. Remove the `[mounts]` section from `fly.toml`, then create the app and set
   the secrets. Do not create a volume.

   ```sh
   fly launch --no-deploy
   fly secrets set --stage DATABASE_PROVIDER=turso \
     DATABASE_URL="libsql://custyard-<org>.turso.io" TURSO_AUTH_TOKEN="..." \
     SECRET_KEY_BASE="$(openssl rand -base64 64)" \
     CREDENTIAL_ENCRYPTION_KEY="$(openssl rand -base64 32)" \
     LETTERMINT_PROJECT_TOKEN="..." INSTANCE_ADMIN_EMAIL=you@example.com
   ```

3. Deploy a CI-built image by digest. The `publish` job of a green `main`
   pipeline prints `Deploy by digest: <image>@<digest>` and records it in
   `published-image.json` ([container publishing](container-publishing.md)).
   A bare `fly deploy` builds `Containerfile` locally instead, which is not
   the image CI tested.

   ```sh
   fly deploy --ha=false --image registry.gitlab.com/custyard/custyard@sha256:<digest>
   fly scale count 1
   ```

   Turso lifts the single-machine refusal, but nothing else about running
   several machines has been tested ([Limits](database.md#limits)).

4. Sign in at `https://<PHX_HOST>/admin/login` as `INSTANCE_ADMIN_EMAIL`, then
   `fly secrets unset INSTANCE_ADMIN_EMAIL`. Read the boot report at the top of
   `fly logs` after every deploy: a configuration problem serves the doctor
   card while the Fly check stays green.

The Fly check uses `/api/health/live`, which answers whenever the process is
up and needs no `Host` header. `/api/health` is readiness (200 only when the
app and database are up); use it for monitoring.

## Move an existing app to Turso

For an app whose SQLite file, logos and attachments are on the `custyard_data`
volume. The app is down from step 3 to step 7; steps 1 and 2 decide whether to
start. Background and rollback are in
[Database operations](database.md#moving-an-existing-sqlite-database).

1. `fly secrets list` must not show `DATABASE_URL`, `TURSO_AUTH_TOKEN` or
   `DATABASE_PROVIDER`. The steps below run against the SQLite file;
   `export_sqlite` refuses a Turso configuration.
2. Snapshot the volume and check space and size. With D the size of
   `custyard.db` and F the size of `/data/uploads` plus `/data/attachments`:
   - `/data` needs D + 2F free, plus a few MB. The import grows the database
     by F, and the export copies the grown database. A full volume fails every
     write while `/api/health/live` stays 200.
   - D + F must stay under 2 GB, the limit of `turso db create --from-file`,
     and within the Turso plan's storage. If it does not, stop here: this
     procedure does not fit.

   ```sh
   fly volumes list
   fly volumes snapshots create <volume-id>
   fly ssh console -C "du -sk /data/custyard.db /data/uploads /data/attachments"
   fly ssh console -C "df -k /data"
   ```

3. Deploy the new image without starting it. In maintenance mode nothing
   listens on port 4000, so the check fails; `immediate` does not wait for it.

   ```sh
   fly secrets set --stage MAINTENANCE_MODE=true
   fly deploy --strategy immediate --image registry.gitlab.com/custyard/custyard@sha256:<digest>
   ```

4. Migrate, then copy the files into the SQLite file. Repeat the import until
   `failed` is 0. What is still `pending` must all be `missing`: files already
   gone from the volume, which no repeat recovers
   ([Upgrading from a release that kept files on disk](database.md#upgrading-from-a-release-that-kept-files-on-disk)).

   ```sh
   fly ssh console -C "runuser -u custyard -- /app/bin/custyard eval 'Custyard.Release.migrate()'"
   fly ssh console -C "runuser -u custyard -- /app/bin/custyard eval 'Custyard.Release.import_legacy_files()'"
   ```

5. Export and download a consistent copy:

   ```sh
   fly ssh console -C "runuser -u custyard -- /app/bin/custyard eval 'Custyard.Release.export_sqlite()'"
   fly ssh sftp get /data/turso-import.db ./turso-import.db
   ```

6. Create the database from the copy, in the group near `ams`. `--from-file`
   only creates; delete an older database of the same name first or pick
   another name. Stage the secrets: applied now, they restart a machine whose
   health check cannot pass, and flyctl reports a failure.

   ```sh
   turso db create custyard --group <group> --from-file ./turso-import.db
   turso db show custyard --url
   turso db tokens create custyard
   fly secrets set --stage DATABASE_PROVIDER=turso DATABASE_URL="libsql://..." TURSO_AUTH_TOKEN="..."
   ```

7. `fly secrets unset MAINTENANCE_MODE` applies all staged secrets and starts
   the app on Turso. Sign in, open recent threads, load a
   tenant logo and download an attachment. Then
   `fly ssh console -C "rm /data/turso-import.db"`.

Never start the app on a database without the production rows while the
volume is mounted: the daily retention sweep deletes every file under
`ATTACHMENT_DIR` that no attachment row refers to.

While the app runs on Turso, every boot logs `unused_local_database_detected`
as long as `/data/custyard.db` exists.

To go back, set `MAINTENANCE_MODE=true`, then unset `DATABASE_PROVIDER`,
`DATABASE_URL` and `TURSO_AUTH_TOKEN`. The app serves the file as it was at
the export: everything written to Turso since is lost unless copied back by
hand, and every `bin/dsar` erasure run since must be run again against the
file before users return.

When the file is no longer wanted as a way back, follow
[Removing the volume](database.md#removing-the-volume): remove `[mounts]`,
deploy, check a logo and an attachment, `fly volumes destroy <id>`, and unset
`UPLOAD_DIR`, `ATTACHMENT_DIR`, `DATA_VOLUME_ID` and `DATABASE_PATH`.

## Promote a verified image

CI deploys only staging to Fly: `promote:staging` runs
`fly deploy --config fly.staging.toml --app custyard-staging --image <image>@<digest> --ha=false`
with the digest from a green `main` pipeline's `published-image.json`
([Bunny setup](bunny-setup.md#keep-staging-separate-and-promote-a-verified-image)).
`promote:production` updates Bunny, not this app. The production Fly app is
deployed by hand with the same digest, as above.

## Back up and restore

Logos and attachments are rows, so the database backup is the whole backup.
Use Turso's own tools (`turso db shell custyard .dump`, or its point-in-time
restore into a new database); none has been rehearsed with the 256 KiB file
chunks. After a restore, run the query in
[Checking stored files](database.md#checking-stored-files) and
`Custyard.Release.import_legacy_files()` before admitting writers. Keep the
last volume snapshot until Turso restores have been rehearsed. Keep
`CREDENTIAL_ENCRYPTION_KEY` and `SECRET_KEY_BASE` with the backup record.
