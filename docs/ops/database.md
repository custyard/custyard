# Database operations

The database is SQLite, either as a file on the Fly volume or as a
[Turso](https://turso.tech) database reached over HTTP. Both run the same
schema and SQL through `Custyard.Repo.Adapter`, and `DATABASE_URL` picks one
at boot, so the same image serves either and a database moves between them
without converting a row.

| `DATABASE_URL` | Database |
| --- | --- |
| unset | SQLite file at `DATABASE_PATH` (default `/data/custyard.db`) on the volume |
| `libsql://<database>-<org>.turso.io` | Turso, authenticated with `TURSO_AUTH_TOKEN` |

PostgreSQL needs a release compiled with `Ecto.Adapters.Postgres` and a
`postgres://` `DATABASE_URL`. Bunny Database is reached through the same
driver as Turso; its settings are in [Set up Custyard on Bunny](bunny-setup.md).

The database also holds every uploaded tenant logo and the content of every
inbound email attachment. A deployment on a remote database therefore needs no
volume, and a database backup includes the files. See
[Files in the database](#files-in-the-database).

## Local SQLite

On Fly.io, `fly.toml` mounts the `custyard_data` volume at `/data`; startup
checks the mount before the Repo or migrations run.

Create the volume in the app's primary region before the first deploy:

```sh
fly volumes create custyard_data --region <your-region> --size 1
fly volumes list
```

Run one app machine (`fly scale count 1`). With a local SQLite file, startup
stops at the database card when the app has more than one machine: each
machine would have its own volume and its own copy of the database. A remote
database is checked for neither a mount nor a machine count. Before a schema
repair or migration, take a volume snapshot and verify which machine owns the
volume. See
[Fly.io deployment](../flyio-deployment.md#volumes-and-backups).

## Turso

`Custyard.Turso.Connection` speaks Turso's HTTP protocol (Hrana) and hands
results to the same SQLite query layer the local file uses. Migrations run at
boot over HTTP, as they do against the file.

### New database

```sh
turso db create custyard
turso db show custyard --url        # libsql://custyard-<org>.turso.io
turso db tokens create custyard
fly secrets set DATABASE_URL="libsql://custyard-<org>.turso.io" TURSO_AUTH_TOKEN="..."
```

Setting the secrets restarts the app on Turso. It refuses to boot with a
`libsql://` URL and no token.

Create the database in the Turso location nearest the app's Fly region
(`primary_region` in `fly.toml`). A statement outside a transaction is one
HTTPS round trip, and inside one, each statement is a round trip.

### Moving an existing SQLite database

Nothing may write the file between the export and the switch to Turso: such a
write would stay in the file and never reach Turso. `MAINTENANCE_MODE=true`
pauses writes. The entrypoint then runs neither migrations nor the app, and
the machine keeps running, so `fly ssh` still works. The app is down from
step 1 to step 4.

The export carries the files as well as the rows, but only the files that are
already in the database. On an installation upgraded from a release that kept
files on disk, check that the import reports nothing pending
([Upgrading from a release that kept files on disk](#upgrading-from-a-release-that-kept-files-on-disk))
before step 1. Files imported after the move are written to Turso over HTTP,
which is slower, and the volume has to stay mounted until they are in.

1. Stop the app:

   ```sh
   fly secrets set MAINTENANCE_MODE=true
   ```

   `fly logs` shows `MAINTENANCE_MODE is true` once the machine has restarted.
   Health checks fail until step 4, so `fly secrets` may report that the
   machine did not become healthy. That is expected here.

2. Export a snapshot and copy it off the machine. `VACUUM INTO` writes a
   consistent copy:

   ```sh
   fly ssh console -C "runuser -u custyard -- /app/bin/custyard eval 'Custyard.Release.export_sqlite()'"
   fly ssh sftp get /data/turso-import.db ./turso-import.db
   ```

3. Create the Turso database from it, then set the secrets. The machine
   restarts and stays in maintenance mode:

   ```sh
   turso db create custyard --from-file ./turso-import.db
   turso db show custyard --url
   turso db tokens create custyard
   fly secrets set DATABASE_URL="libsql://..." TURSO_AUTH_TOKEN="..."
   ```

4. Start the app on Turso:

   ```sh
   fly secrets unset MAINTENANCE_MODE
   ```

5. Log in and check that recent threads are there. Then remove the
   export with `fly ssh console -C "rm /data/turso-import.db"`.

Every boot logs a warning while `/data/custyard.db` is still on the volume.
Keep it until you are satisfied, then delete it. To go back, unset
`DATABASE_URL` and `TURSO_AUTH_TOKEN`: the app serves the file again, without
anything written to Turso in the meantime. That includes logos and
attachments stored after the move, which are in Turso only.

A `DATABASE_URL=libsql://...` line left in `.env.secrets` from before Turso
worked will now switch the app to that database on the next
`mix fly.secrets --apply`. Check the file before applying it.

### The volume after the move

Nothing the app reads has to stay on it: logos and attachments are rows in
the database. The volume and the `[mounts]` section can go once the old
SQLite file is no longer wanted as a way back and the import of files from an
earlier release reports nothing pending. See
[Removing the volume](#removing-the-volume).

### Limits

- **One machine, until more are tested.** Startup no longer refuses a second
  machine on a remote database: files are in the database, so every machine
  reads the same ones. That check is the only part of running several
  machines this change addresses. Erlang distribution is off, so live updates
  do not cross machines, and each machine starts its own schedulers, outbound
  queue and mail pollers. Keep `fly scale count 1` until that has been
  tested.
- **Short transactions.** A transaction keeps a server-side stream open,
  which expires when left idle for a few seconds and ends the transaction.
- **No embedded replica.** Reads go to Turso every time; there is no local
  copy synced from it.
- **The turso CLI owns the database.** `mix ecto.create` and `mix ecto.drop`
  never touch it, and `mix ecto.dump` needs a local file; use
  `turso db shell custyard` instead.

### Testing against libSQL

`TURSO_TEST_URL` runs the test suite over the Turso driver. CI's `turso` job
points it at the libSQL server image; locally, the bundled test server does:

```sh
MIX_ENV=test mix run --no-start -e 'Custyard.TursoTestServer.serve(port: 8089)'
TURSO_TEST_URL='libsql://127.0.0.1:8089?tls=0' mix test
```

`?tls=0` selects plain HTTP, and a server on plain HTTP may run without a
token.

## Files in the database

Tenant logos and the content of inbound email attachments are rows in the
application database: one `stored_files` row per file, with its content in
`stored_file_chunks`. Local SQLite, Turso and Bunny Database use the same
tables and the same code. The app writes no logo or attachment to disk and
reads none from disk when serving a request. The migration
`20261112000000_create_stored_files` creates the tables at boot like any
other.

### Which deployments need a volume

| Database | Volume |
| --- | --- |
| Local SQLite file (`DATABASE_URL` unset) | Yes, for the database file itself (`DATABASE_PATH`, default `/data/custyard.db`). |
| Turso, Bunny Database or PostgreSQL | No. |

The one exception is an upgrade: a deployment that has logos or attachments
on disk from an earlier release keeps that volume mounted until
[the import](#upgrading-from-a-release-that-kept-files-on-disk) has finished.

`STORAGE_PROVIDER` selects what startup checks before it opens the database.
Unset, it is `fly` when `FLY_APP_NAME` is present and `local` otherwise.

| `STORAGE_PROVIDER` | Checked before the database is opened |
| --- | --- |
| `local` | Nothing. With a SQLite file, keeping its directory on persistent storage is up to you; `docker-compose.yml` mounts a named volume at `/data`. |
| `fly` | With a local SQLite file: `DATABASE_PATH` is under `/data`, `/data` is a mounted volume, and the app has one machine. With a remote database: nothing. |
| `bunny` | The database is the configured Bunny Database. No volume is involved; a SQLite file or any other database is refused. |

A failed check stops boot at the database card, which names the fix.
`bin/doctor --probe-database` reports the same from a shell.

### Variables and commands that changed

- `UPLOAD_DIR` (default `/data/uploads`) and `ATTACHMENT_DIR` (default
  `/data/attachments`) name the directories where earlier releases wrote
  logos and attachments. Only the import described below reads them. Neither
  is checked at boot, neither has to exist, and nothing is written there. A
  deployment that never kept files on disk leaves both unset.
- `DATA_VOLUME_ID` is no longer used. A deployment that still sets it boots
  as before, with a warning in the boot report saying it can be removed.
- `bin/data-volume` (`init`, `backup`, `restore`) is no longer in the image.
  The `/data/.custyard-volume` marker it wrote and its
  `.custyard-restore-in-progress` guard are not read any more. Remove calls
  to it from deployment and backup scripts.

### Upgrading from a release that kept files on disk

Earlier releases wrote each logo to `UPLOAD_DIR/logos/` and each fetched
attachment to `ATTACHMENT_DIR/<tenant id>/<first two characters of its
SHA-256>/<SHA-256>`. The rows that refer to those files are still in the
database. This release copies every referenced file into the database.

1. Take a backup of the volume first
   ([backup and restore](backup-restore.md)). With a local SQLite database,
   also check free space: the copies go into the database file on the same
   volume and the originals stay, so the volume holds both until you delete
   the directories.
2. Deploy with the volume still mounted and `UPLOAD_DIR` and
   `ATTACHMENT_DIR` as they were. Left unset, they default to the paths
   earlier releases used.
3. Boot creates the two tables and, as the last step of startup, starts the
   import in the background. Neither boot nor a health check waits for it.
   It runs on every boot that still has something to import and does nothing
   otherwise. With `MAINTENANCE_MODE=true` the app is not started, so it does
   not run.
4. Read the result with the release command below. `pending 0` means it has
   finished.

The import copies only files that a row refers to: `message_attachments` rows
in state `fetched`, and `tenants.logo_url`. A file on disk that nothing
refers to is left out. Attachments go first, then logos. Each file must be a
regular file (a symlink or a directory is refused), at most 100 MiB for an
attachment or 2,000,000 bytes for a logo, and an attachment's content must
have the SHA-256 it is named by. Nothing on disk is written, moved or
deleted, and attachment rows are not changed, so scan verdicts stay as they
were.

Until a file has been imported, its logo URL and its attachment download
answer 404. Do not rescan attachments in that time, with
`Custyard.Release.scan_attachments()` or a thread's rescan control: an
attachment that is not in the database yet ends with an error verdict and
stays quarantined until a later rescan
([attachment scanning](attachment-scanning.md#scan-existing-files-and-retry-failures)).

Run the command as `custyard`. It starts only the database, never the app, so
it is safe while the server runs, and running it again is safe:

```sh
# Fly
fly ssh console -C "runuser -u custyard -- /app/bin/custyard eval 'Custyard.Release.import_legacy_files()'"

# A shell in the container, which already runs as custyard
/app/bin/custyard eval 'Custyard.Release.import_legacy_files()'
```

```text
Legacy file import
  imported  41 attachments, 1 logo
  missing   0
  failed    0
  pending   0
Every referenced file is in the database. ATTACHMENT_DIR and UPLOAD_DIR are
no longer read.
```

| Line | Meaning |
| --- | --- |
| `imported` | Files this run copied into the database. A later run reports 0 for files an earlier run or the boot import already copied. |
| `missing` | Files a row refers to that are not under `UPLOAD_DIR` or `ATTACHMENT_DIR`. |
| `failed` | Files that are there but were refused (not a regular file, too large, or not the content the row names), could not be read, or could not be stored. |
| `pending` | Referenced files still not in the database after this run. Identical attachment content counts once per tenant, however many messages carry it. |

The boot import writes the same counts to the log as one
`legacy_file_import_completed` event with `imported_attachments`,
`imported_logos`, `missing_files` and `failed_files`, at warning level when
anything was missing or failed. `legacy_file_import_failed` means the boot
import itself crashed; the next boot tries again. A boot with nothing to
import logs neither event. The log never carries a path, key, hash or
filename.

If `pending` stays above 0:

- Check that the volume is mounted and that `UPLOAD_DIR` and `ATTACHMENT_DIR`
  point at the directories the earlier release wrote to. A wrong path shows
  up as `missing`.
- A `missing` file that is not on the volume at all was already unavailable
  before the upgrade. It stays pending, and every boot repeats the warning.
- A `failed` file is still on the volume and is lost when the volume goes.
  Look at these before removing anything.

To roll back to the earlier release, keep the directories: nothing in them
changed, so that release still finds every file it wrote. Logos and
attachments received after the upgrade exist only in the database, and an
earlier release does not read them.

### Removing the volume

A volume is still needed while either of these is true:

- the database is a local SQLite file, which lives on it;
- the import above reports files pending that are still on it.

With a local SQLite database the volume stays. Once `pending` is 0 and a
backup exists, the `uploads` and `attachments` directories on it can be
deleted; the app does not read them again.

With a remote database the volume can go once `pending` is 0, or once
`failed` is 0 and everything still pending is `missing`:

1. Keep a last snapshot or archive of it for as long as a rollback to the
   earlier release, or to the old SQLite file, is still possible.
2. On Fly, remove the `[mounts]` section from the app's configuration and
   deploy. Fly replaces the machine with one that has no volume
   ([Fly volume management](https://fly.io/docs/volumes/volume-manage/)). On
   other hosts, remove the volume from the container's configuration.
3. Check a tenant logo and an attachment download, then destroy the volume
   (`fly volumes list`, `fly volumes destroy <volume-id>`).
4. Remove `UPLOAD_DIR`, `ATTACHMENT_DIR`, `DATA_VOLUME_ID` and
   `DATABASE_PATH` from the environment where they are set.

### Size and limits

- **Chunks.** Content is stored in pieces of 256 KiB, each written as its
  own statement outside any transaction, and read back about 1 MiB at a
  time. Remote libSQL servers force this: in testing, sqld 0.24.31 accepted
  a 4 MB blob in one statement, rejected 8 MB, and caps a response at about
  10 MB. Over libSQL, blobs travel as base64 in JSON, so anything between
  the app and the database (a self-hosted sqld, a proxy) has to pass a
  request of about 350 KB and a response of about 1.4 MB.
- **Time.** On a remote database every chunk is one HTTP request: about four
  requests per megabyte stored. Importing a large attachment directory takes
  correspondingly long, which is why the import runs in the background.
- **File size.** A logo is at most 2,000,000 bytes. Attachments are bounded
  by each channel's per-message limit, 0 to 100 MB (default 10).
- **Database size.** File content counts toward the size of the database and
  toward any size limit the provider sets. Check that limit before importing
  a large attachment directory into a remote database.
- **Cleanup.** The daily retention sweep removes attachment content that no
  message refers to any more once it is a day old, and writes that were
  started and never finished after an hour.

### Checking stored files

This query lists published files whose chunks are missing or do not add up to
the recorded size. It returns numbers only and runs in any SQL shell
(`sqlite3`, `turso db shell`). No rows means every file is complete:

```sql
SELECT f.id, f.kind, f.size, f.chunk_count,
       COUNT(c.position) AS chunks,
       COALESCE(SUM(LENGTH(c.data)), 0) AS bytes
FROM stored_files f
LEFT JOIN stored_file_chunks c ON c.file_id = f.id
WHERE f.completed_at IS NOT NULL
GROUP BY f.id
HAVING COUNT(c.position) <> f.chunk_count
    OR COALESCE(SUM(LENGTH(c.data)), 0) <> f.size;
```

A row with `completed_at` null is a write in progress or one that was
abandoned; the sweep removes it. The query does not check the SHA-256. The
app checks it whenever it reads a whole file (a logo request, an attachment
rescan), and the restore drill in [backup and restore](backup-restore.md)
checks it for every file in a SQLite copy. An attachment download streams the
content and stops at a missing chunk.

## Legacy schema mismatch

An earlier version renamed `resume_token_hash` to `access_token_hash` inside
an already applied migration. An existing database with the old column can
fail with `no such column: access_token_hash`. Preserve and back up any
production data before applying a forward schema repair. Recreating a local
development or test database is appropriate only when its contents are
disposable.
