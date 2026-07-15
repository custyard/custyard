# docs/ops/database.md
---

## ⚠️ Start fresh: delete and recreate your database

Migration `20260705150001_create_prospects.exs` was renamed in-place (`resume_token_hash` → `access_token_hash`) after existing databases had already run it, so `schema_migrations` marks it complete with the old schema. Stale DBs fail with `no such column: access_token_hash` (262 test failures). Reset to start fresh:

### Local SQLite (dev + test)

```sh
# test DB (including MIX_TEST_PARTITION variants) — recreated automatically on next `mix test`
rm -f priv/repo/custyard_test*.db*

# dev DB — recreate + migrate + seed
rm -f priv/repo/custyard_dev.db*
mix ecto.setup        # or: mix ecto.reset (drops + recreates in one step)
```

### Turso (production, `libsql://` DATABASE_URL)

```sh
turso db destroy <db-name> --yes
turso db create <db-name>
turso db show <db-name> --url          # new libsql:// URL
turso db tokens create <db-name>       # new auth token

fly secrets set DATABASE_URL="libsql://…" TURSO_AUTH_TOKEN="…"   # triggers restart

# migrate and recreate the operator account (use rpc, not eval, against the running app)
fly ssh console -C "/app/bin/custyard rpc 'Custyard.Release.migrate()'"
fly ssh console -C "/app/bin/custyard rpc 'Custyard.Release.setup_operator(\"lettermint@solutious.com\")'"
```

turso db destroy cydb1-onetime
turso db create cydb1-onetime
turso db show --url cydb1-onetime
