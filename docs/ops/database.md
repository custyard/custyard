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
`postgres://` `DATABASE_URL`.

## Local SQLite

On Fly.io, `fly.toml` mounts the `custyard_data` volume at `/data`; startup
checks the mount before the Repo or migrations run.

Create the volume in the app's primary region before the first deploy:

```sh
fly volumes create custyard_data --region <your-region> --size 1
fly volumes list
```

Keep one app machine per SQLite database. Before a schema repair or migration,
take a volume snapshot and verify which machine owns the volume. See
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

1. Export a snapshot on the running machine. It is a consistent copy taken with
   `VACUUM INTO`; writes after it are not in it, so pick a quiet moment.

   ```sh
   fly ssh console -C "/app/bin/custyard eval Custyard.Release.export_sqlite()"
   fly ssh sftp get /data/turso-import.db ./turso-import.db
   ```

2. Create the Turso database from it, then set the secrets:

   ```sh
   turso db create custyard --from-file ./turso-import.db
   turso db show custyard --url
   turso db tokens create custyard
   fly secrets set DATABASE_URL="libsql://..." TURSO_AUTH_TOKEN="..."
   ```

3. Log in and check that recent conversations are there. Then remove the
   export with `fly ssh console -C "rm /data/turso-import.db"`.

Every boot logs a warning while `/data/custyard.db` is still on the volume.
Keep it until you are satisfied, then delete it. To go back, unset
`DATABASE_URL` and `TURSO_AUTH_TOKEN`: the app serves the file again, without
anything written to Turso in the meantime.

A `DATABASE_URL=libsql://...` line left in `.env.secrets` from before Turso
worked will now switch the app to that database on the next
`mix fly.secrets --apply`. Check the file before applying it.

### What stays on the volume

Uploads (`/data/uploads`) and inbound email attachments (`/data/attachments`)
are files, not rows. Keep the volume and the `[mounts]` section.

### Limits

- **One machine.** The machine-count check only guards a local database file,
  but uploads and attachments live on one machine's volume, and the outbound
  mail queue is written as the only sender in a single-node deployment. Keep
  `fly scale count 1`.
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

## Legacy schema mismatch

An earlier version renamed `resume_token_hash` to `access_token_hash` inside
an already applied migration. An existing database with the old column can
fail with `no such column: access_token_hash`. Preserve and back up any
production data before applying a forward schema repair. Recreating a local
development or test database is appropriate only when its contents are
disposable.
