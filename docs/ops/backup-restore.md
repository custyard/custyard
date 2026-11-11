# Back up and verify a restored volume

The SQLite deployment stores its database, uploads and attachments together on
one Fly volume. A database export alone is incomplete. Keep encryption keys in
the installation's separate secret store: snapshots do not recover lost keys.

## Establish a recovery point

Record the source app, machine, volume, region, volume size and exact image
digest. Resolve these with `fly status --app APP --json`,
`fly machine status MACHINE --app APP --display-config` and
`fly volumes list --app APP`. Never put secrets or customer records in the
evidence log.

Enter maintenance mode for a consistent snapshot of rows and files. This
briefly stops intake and the web application; the machine stays available for
administrative commands. Confirm the logs say `MAINTENANCE_MODE is true`.

```sh
fly secrets set MAINTENANCE_MODE=true --app SOURCE_APP
fly volumes snapshots create SOURCE_VOLUME --app SOURCE_APP --json
fly volumes snapshots list SOURCE_VOLUME --app SOURCE_APP --json
```

Wait for the snapshot to finish. Record its ID and time, then resume service:

```sh
fly secrets unset MAINTENANCE_MODE --app SOURCE_APP
```

A running-volume snapshot provides crash recovery, but does not establish
that attachment files and database rows were captured together. Maintain an
independent encrypted backup outside the hosting account as well. While in
maintenance mode, archive the database and SQLite sidecars, `uploads/` and
`attachments/` together; copy it off the machine and restrict local access to
its owner. Never publish this archive as a build artifact.

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
not call `Custyard.Release.with_repo/1` or start Custyard.

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

attachments = query.("SELECT tenant_id, sha256, storage_path FROM message_attachments WHERE state = 'fetched'")

Enum.each(attachments, fn [tenant_id, hash, relative] ->
  true = is_binary(hash) and String.match?(hash, ~r/\A[0-9a-f]{64}\z/)
  ^relative = Path.join([to_string(tenant_id), String.slice(hash, 0, 2), hash])
  bytes = File.read!(Path.join("/restore/attachments", relative))
  ^hash = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
end)

uploads =
  Path.wildcard("/restore/uploads/**/*", match_dot: true)
  |> Enum.filter(&File.regular?/1)
  |> Enum.sort()
  |> Enum.map(fn path ->
    bytes = File.read!(path)
    {Path.relative_to(path, "/restore/uploads"), byte_size(bytes), :crypto.hash(:sha256, bytes)}
  end)

uploads_hash =
  uploads
  |> :erlang.term_to_binary()
  |> then(&:crypto.hash(:sha256, &1))
  |> Base.encode16(case: :lower)

:ok = Exqlite.Sqlite3.close(db)
IO.inspect(%{integrity: :ok, foreign_keys: :ok, row_counts: counts,
  verified_attachments: length(attachments), upload_files: length(uploads),
  upload_manifest_sha256: uploads_hash}, label: "restore_verification")
```

Record only snapshot ID/time, image digest, drill resource IDs, verification
summary, elapsed restore time and cleanup result. Compare row counts and the
upload manifest with the same read-only checks taken at the recovery point.
Zero attachments does not exercise attachment restoration; record that limit.

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
