# Back up and verify a restored volume

The SQLite deployment stores its database on one Fly volume, and the database
holds uploaded logos and attachment content as well as the rows
([Files in the database](database.md#files-in-the-database)). A consistent
copy of the database is therefore a complete backup. The one exception is an
installation upgraded from a release that kept files on disk: until its
import reports nothing pending, the `uploads/` and `attachments/` directories
on the volume belong in the backup too. Keep encryption keys in the
installation's separate secret store: snapshots do not recover lost keys.

A deployment on a remote database (Turso, Bunny Database) has no volume to
snapshot. Back it up with the provider's export. The files are ordinary rows
in it, stored as 256 KiB blobs; rehearse a restore to confirm the provider's
tooling carries them intact, and check the restored copy with the query in
[Checking stored files](database.md#checking-stored-files). The drill below
is for the SQLite file on a Fly volume.

## Establish a recovery point

Record the source app, machine, volume, region, volume size and exact image
digest. Resolve these with `fly status --app APP --json`,
`fly machine status MACHINE --app APP --display-config` and
`fly volumes list --app APP`. Never put secrets or customer records in the
evidence log.

Enter maintenance mode for a consistent snapshot. This briefly stops intake
and the web application; the machine stays available for administrative
commands. Confirm the logs say `MAINTENANCE_MODE is true`.

```sh
fly secrets set MAINTENANCE_MODE=true --app SOURCE_APP
fly volumes snapshots create SOURCE_VOLUME --app SOURCE_APP --json
fly volumes snapshots list SOURCE_VOLUME --app SOURCE_APP --json
```

Wait for the snapshot to finish. Record its ID and time, then resume service:

```sh
fly secrets unset MAINTENANCE_MODE --app SOURCE_APP
```

A running-volume snapshot provides crash recovery, not a copy taken with
writers stopped. Maintain an independent encrypted backup outside the hosting
account as well. While in maintenance mode, archive the database and its
SQLite sidecars together; `Custyard.Release.export_sqlite()`
([database operations](database.md#moving-an-existing-sqlite-database))
writes the same content as one file. Until the import of files from an
earlier release reports nothing pending, add `uploads/` and `attachments/` to
the archive. Copy it off the machine and restrict local access to its owner.
Never publish this archive as a build artifact.

## Restore into a separate app

Create a disposable Fly app in the same organization. It must have no services,
production secrets or application processes. Keep exactly one machine in the
production app.

```sh
fly apps create DRILL_APP --org SOURCE_ORG
fly volumes create restore_data --app DRILL_APP --region SOURCE_REGION \
  --snapshot-id SNAPSHOT_ID --size SOURCE_SIZE_GB --json
```

Save this machine configuration locally, substituting the cloned volume ID.
The key base below is a disposable value for loading release configuration.

```json
{
  "init": {"entrypoint": ["/bin/sleep"], "cmd": ["infinity"]},
  "env": {
    "MAIL_ADAPTER": "local",
    "OUTBOUND_DELIVERY_ENABLED": "false",
    "SECRET_KEY_BASE": "restore-drill-only-000000000000000000000000000000000000000000000000",
    "DATABASE_PATH": "/restore/custyard.db",
    "UPLOAD_DIR": "/restore/uploads",
    "ATTACHMENT_DIR": "/restore/attachments"
  },
  "services": [],
  "mounts": [{"volume": "CLONED_VOLUME_ID", "path": "/restore"}],
  "guest": {"cpu_kind": "shared", "cpus": 1, "memory_mb": 512},
  "restart": {"policy": "no"}
}
```

`UPLOAD_DIR` and `ATTACHMENT_DIR` matter only when the snapshot predates a
finished import of files from an earlier release: they tell a restored
installation where the files it still has to import are. The verification
below does not read them.

Run the source image with this explicit configuration. It contains Exqlite, so
no downloaded database utility is needed.

```sh
fly machine run SOURCE_IMAGE_DIGEST --app DRILL_APP \
  --machine-config /absolute/path/restore-machine.json \
  --name restore-verification --skip-dns-registration --detach
fly machine status DRILL_MACHINE --app DRILL_APP --display-config
```

Confirm the resulting machine has `services: []`, the cloned mount,
`/bin/sleep` as its entrypoint and no production secrets. Do not start Custyard,
migrations, mail workers, pollers or the scanner. The `local` mailer alone is
insufficient protection: tenant sending credentials live in the database.

## Verify without starting Custyard

Save the following script locally and transfer it to
`/tmp/restore-verify.exs` with `fly ssh sftp put --app DRILL_APP --machine
DRILL_MACHINE`. Run it through release `eval`. It starts only Exqlite; it does
not call `Custyard.Release.with_repo/1` or start Custyard. It reads the
`stored_files` tables, so it applies to snapshots taken after the upgrade to
a release that stores files in the database; for an older snapshot use the
drill from the release that took it.

```sh
fly ssh console --app DRILL_APP --machine DRILL_MACHINE \
  -C "runuser -u custyard -- /app/bin/custyard eval 'Code.eval_file(\"/tmp/restore-verify.exs\")'"
```

```elixir
if Enum.any?(Application.started_applications(), fn {app, _, _} -> app == :custyard end),
  do: raise("refusing verification while Custyard is running")

{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, db} = Exqlite.Sqlite3.open("/restore/custyard.db", mode: :readonly)

query = fn sql ->
  {:ok, statement} = Exqlite.Sqlite3.prepare(db, sql)
  {:ok, rows} = Exqlite.Sqlite3.fetch_all(db, statement)
  :ok = Exqlite.Sqlite3.release(db, statement)
  rows
end

[["ok"]] = query.("PRAGMA integrity_check")
[] = query.("PRAGMA foreign_key_check")

counts =
  for table <- ~w(tenants organizations contacts threads messages message_attachments), into: %{} do
    [[count]] = query.("SELECT COUNT(*) FROM #{table}")
    {table, count}
  end

# Every published file: each chunk present, the recorded size and SHA-256.
# One chunk is in memory at a time.
files =
  query.("""
  SELECT id, tenant_id, kind, key, sha256, size, chunk_count
  FROM stored_files WHERE completed_at IS NOT NULL ORDER BY id
  """)

Enum.each(files, fn [id, _tenant_id, _kind, _key, hash, size, chunk_count] ->
  {digest, bytes} =
    Enum.reduce(0..(chunk_count - 1)//1, {:crypto.hash_init(:sha256), 0}, fn position, {digest, bytes} ->
      [[data]] =
        query.("SELECT data FROM stored_file_chunks WHERE file_id = #{id} AND position = #{position}")

      {:crypto.hash_update(digest, data), bytes + byte_size(data)}
    end)

  ^size = bytes
  ^hash = Base.encode16(:crypto.hash_final(digest), case: :lower)
end)

files_hash =
  files
  |> Enum.map(fn [_id, tenant_id, kind, key, hash, size, _chunks] -> {tenant_id, kind, key, hash, size} end)
  |> Enum.sort()
  |> :erlang.term_to_binary()
  |> then(&:crypto.hash(:sha256, &1))
  |> Base.encode16(case: :lower)

# Fetched attachments and tenant logos whose content is not in the database.
[[unimported_attachments]] =
  query.("""
  SELECT COUNT(*) FROM (
    SELECT DISTINCT a.tenant_id, a.sha256 FROM message_attachments a
    WHERE a.state = 'fetched' AND a.sha256 IS NOT NULL AND NOT EXISTS (
      SELECT 1 FROM stored_files f
      WHERE f.kind = 'attachment' AND f.completed_at IS NOT NULL
        AND f.tenant_id = a.tenant_id AND f.key = a.sha256))
  """)

logos = query.("SELECT tenant_id, key FROM stored_files WHERE kind = 'logo' AND completed_at IS NOT NULL")

unimported_logos =
  query.("SELECT id, logo_url FROM tenants WHERE logo_url LIKE '/uploads/logos/%'")
  |> Enum.count(fn [tenant_id, logo_url] ->
    with "/uploads/logos/" <> name <- logo_url do
      ext = Path.extname(name)
      [tenant_id, String.replace_suffix(name, ext, String.downcase(ext))] not in logos
    else
      _ -> false
    end
  end)

:ok = Exqlite.Sqlite3.close(db)
IO.inspect(%{integrity: :ok, foreign_keys: :ok, row_counts: counts,
  verified_files: length(files), file_manifest_sha256: files_hash,
  unimported_attachments: unimported_attachments, unimported_logos: unimported_logos},
  label: "restore_verification")
```

Record only snapshot ID/time, image digest, drill resource IDs, verification
summary, elapsed restore time and cleanup result. Compare row counts and the
file manifest hash with the same read-only checks taken at the recovery point.
`verified_files: 0` does not exercise file restoration; record that limit.

`unimported_attachments` or `unimported_logos` above 0 means rows refer to
files that are not in the database. Either the snapshot predates a finished
import, and those files are under `uploads/` and `attachments/` on the
restored volume, or they were already missing at the source. A restored
installation imports what is on the volume on its first boot when
`UPLOAD_DIR` and `ATTACHMENT_DIR` point at those directories; see
[Upgrading from a release that kept files on disk](database.md#upgrading-from-a-release-that-kept-files-on-disk).

This proves storage recovery, not mailbox delivery or complete application
recovery. Test migrations against a disposable restored copy before deploying
schema changes. A real failover must start with outbound delivery paused and
reconcile pending/uncertain messages against provider activity before resuming.

## Remove only drill resources

For an actual failover, set installation environment
`OUTBOUND_DELIVERY_ENABLED=false` before starting the restored installation.
This holds all tenants' queued customer replies, including older snapshots
without tenant pause controls. The value is strictly `true` or `false` and
defaults to `true`. Re-enable it after reconciliation; individual tenant
administrators can still hold their own tenant's mail.

Check each ID belongs to the disposable app before running:

```sh
fly machine stop DRILL_MACHINE --app DRILL_APP
fly machine destroy DRILL_MACHINE --app DRILL_APP
fly volumes destroy CLONED_VOLUME_ID --app DRILL_APP --yes
fly apps destroy DRILL_APP --yes
```

The snapshot and source volume remain intact. The current CLI restores with
`volumes create --snapshot-id`; it has no `volumes snapshots restore` command.
See [Fly volume management](https://fly.io/docs/volumes/volume-manage/)
and [custom machine entrypoints](https://fly.io/docs/machines/flyctl/fly-machine-run/).
