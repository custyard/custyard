# Database operations

Production uses SQLite at `/data/custyard.db` by default. On Fly.io, `fly.toml`
mounts the `custyard_data` volume at `/data`; startup checks the mount before
the Repo or migrations run. Uploaded files also live under `/data/uploads`.

Create the volume in the app's primary region before the first deploy:

```sh
fly volumes create custyard_data --region <your-region> --size 1
fly volumes list
```

Keep one app machine per SQLite database. Before a schema repair or migration,
take a volume snapshot and verify which machine owns the volume. See
[Fly.io deployment](../flyio-deployment.md#volumes-and-backups).

`DATABASE_URL=libsql://...` is unsupported. The locked SQLite driver does not
connect to Turso; it interprets the URL as a local filename. Runtime
configuration rejects it so a deployment cannot silently create an ephemeral
database. PostgreSQL requires a release built with `Ecto.Adapters.Postgres` and
a PostgreSQL `DATABASE_URL`.

## Legacy schema mismatch

An earlier version renamed `resume_token_hash` to `access_token_hash` inside
an already applied migration. An existing database with the old column can
fail with `no such column: access_token_hash`. Preserve and back up any
production data before applying a forward schema repair. Recreating a local
development or test database is appropriate only when its contents are
disposable.
