defmodule Custyard.Repo.Migrations.CreateTenants do
  use Ecto.Migration

  # SQLite requires foreign_keys OFF before BEGIN when rebuilding a referenced
  # table. Keep the entire ownership conversion in our own transaction instead.
  @disable_ddl_transaction true

  def up do
    execute fn ->
      with_rebuild_transaction(fn ->
        sql("""
        CREATE TABLE tenants (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          name TEXT NOT NULL, slug TEXT NOT NULL, custom_domain TEXT,
          logo_url TEXT, primary_color TEXT, secondary_color TEXT,
          inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL
        )
        """)

        sql("CREATE UNIQUE INDEX tenants_slug_index ON tenants(slug)")
        sql("CREATE UNIQUE INDEX tenants_custom_domain_index ON tenants(custom_domain)")

        sql(
          "INSERT INTO tenants (id,name,slug,inserted_at,updated_at) VALUES (1,'Default','default',CURRENT_TIMESTAMP,CURRENT_TIMESTAMP)"
        )

        sql(
          "ALTER TABLE organizations ADD COLUMN tenant_id INTEGER NOT NULL DEFAULT 1 REFERENCES tenants(id)"
        )

        sql("ALTER TABLE organizations ADD COLUMN intake_key TEXT")
        sql("DROP INDEX organizations_domain_index")

        sql(
          "CREATE UNIQUE INDEX organizations_tenant_id_domain_index ON organizations(tenant_id,domain) WHERE domain IS NOT NULL AND domain != ''"
        )

        sql(
          "CREATE UNIQUE INDEX organizations_tenant_id_intake_key_index ON organizations(tenant_id,intake_key)"
        )

        sql(
          "ALTER TABLE operator_accounts ADD COLUMN tenant_id INTEGER REFERENCES tenants(id) ON DELETE SET NULL"
        )

        # Existing organization-scoped staff retain their narrower permissions.
        # An instance administrator explicitly grants tenant access after review.

        for table <-
              ~w(conversations intake_sources inbound_routes inbound_channels inbound_channel_rejections) do
          sql(
            "ALTER TABLE #{table} ADD COLUMN tenant_id INTEGER NOT NULL DEFAULT 1 REFERENCES tenants(id)"
          )

          sql("CREATE INDEX #{table}_tenant_id_index ON #{table}(tenant_id)")
        end

        for table <- ~w(inbound_routes inbound_channels inbound_channel_rejections),
            do: organization_nullability(table, true)

        assert_foreign_keys!()
      end)
    end
  end

  def down do
    execute fn ->
      with_rebuild_transaction(fn ->
        %{rows: [[count]]} = sql("SELECT COUNT(*) FROM tenants WHERE id != 1")
        if count > 0, do: raise("Consolidate tenant data before rolling back tenant ownership")

        for table <- ~w(inbound_routes inbound_channels inbound_channel_rejections) do
          %{rows: [[count]]} = sql("SELECT COUNT(*) FROM #{table} WHERE organization_id IS NULL")

          if count > 0,
            do:
              raise("Assign customer ownership in #{table} before rolling back tenant ownership")
        end

        for table <-
              ~w(inbound_channel_rejections inbound_channels inbound_routes intake_sources conversations) do
          sql("DROP INDEX #{table}_tenant_id_index")
          sql("ALTER TABLE #{table} DROP COLUMN tenant_id")
        end

        for table <- ~w(inbound_routes inbound_channels inbound_channel_rejections),
            do: organization_nullability(table, false)

        sql("ALTER TABLE operator_accounts DROP COLUMN tenant_id")
        sql("DROP INDEX organizations_tenant_id_intake_key_index")
        sql("DROP INDEX organizations_tenant_id_domain_index")
        sql("ALTER TABLE organizations DROP COLUMN intake_key")
        sql("ALTER TABLE organizations DROP COLUMN tenant_id")

        sql(
          "CREATE UNIQUE INDEX organizations_domain_index ON organizations(domain) WHERE domain IS NOT NULL"
        )

        sql("DROP TABLE tenants")
        assert_foreign_keys!()
      end)
    end
  end

  defp organization_nullability(table, nullable?) do
    %{rows: sequence_rows} = sql("SELECT seq FROM sqlite_sequence WHERE name=?", [table])

    sequence =
      case sequence_rows do
        [[value]] -> value
        [] -> 0
      end

    %{rows: [[definition]]} =
      sql("SELECT sql FROM sqlite_master WHERE type='table' AND name=?", [table])

    %{rows: indexes} =
      sql("SELECT sql FROM sqlite_master WHERE type='index' AND tbl_name=? AND sql IS NOT NULL", [
        table
      ])

    definition =
      if nullable? do
        String.replace(
          definition,
          ~s("organization_id" INTEGER NOT NULL),
          ~s("organization_id" INTEGER)
        )
      else
        String.replace(
          definition,
          ~s("organization_id" INTEGER CONSTRAINT),
          ~s("organization_id" INTEGER NOT NULL CONSTRAINT)
        )
      end

    temporary = table <> "_tenant_migration"
    definition = String.replace(definition, ~s("#{table}"), ~s("#{temporary}"), global: false)
    sql(definition)
    sql("INSERT INTO #{temporary} SELECT * FROM #{table}")
    sql("DROP TABLE #{table}")
    sql("ALTER TABLE #{temporary} RENAME TO #{table}")
    # A table rebuild otherwise resets AUTOINCREMENT to the highest surviving
    # row, allowing IDs of deleted rows to be reused after this migration.
    sql("DELETE FROM sqlite_sequence WHERE name=?", [table])
    sql("INSERT INTO sqlite_sequence(name,seq) VALUES(?,?)", [table, sequence])
    Enum.each(indexes, fn [index] -> sql(index) end)
  end

  defp with_rebuild_transaction(fun) do
    repo().checkout(fn ->
      sql("PRAGMA foreign_keys = OFF")

      try do
        case repo().transaction(fun, migration_foreign_keys: :off) do
          {:ok, _} -> :ok
          {:error, reason} -> raise("Tenant migration failed: #{inspect(reason)}")
        end
      after
        sql("PRAGMA foreign_keys = ON")
      end
    end)
  end

  defp assert_foreign_keys! do
    case sql("PRAGMA foreign_key_check") do
      %{rows: []} -> :ok
      _ -> raise("Tenant migration found invalid foreign keys")
    end
  end

  defp sql(statement, params \\ []),
    do: Ecto.Adapters.SQL.query!(repo(), statement, params, log: false)
end
