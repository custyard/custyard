defmodule Custyard.Repo.Migrations.AddProjectTenancy do
  use Ecto.Migration
  @disable_ddl_transaction true

  def up do
    execute fn ->
      with_foreign_keys_disabled(fn ->
        sql(
          "ALTER TABLE projects ADD COLUMN tenant_id INTEGER NOT NULL DEFAULT 1 REFERENCES tenants(id)"
        )

        sql("CREATE INDEX projects_tenant_id_index ON projects(tenant_id)")

        sql(
          "UPDATE projects SET tenant_id = (SELECT tenant_id FROM organizations WHERE organizations.id = projects.organization_id) WHERE organization_id IS NOT NULL"
        )
      end)
    end
  end

  def down do
    execute fn ->
      with_foreign_keys_disabled(fn ->
        sql("DROP INDEX projects_tenant_id_index")
        sql("ALTER TABLE projects DROP COLUMN tenant_id")
      end)
    end
  end

  # SQLite rejects adding a non-null REFERENCES default to a populated table
  # while foreign keys are enabled. The driver option applies OFF on Turso's
  # BEGIN stream; the explicit PRAGMA covers a local SQLite connection.
  defp with_foreign_keys_disabled(fun) do
    repo().checkout(fn ->
      sql("PRAGMA foreign_keys = OFF")

      try do
        repo().transaction(
          fn ->
            fun.()

            case sql("PRAGMA foreign_key_check") do
              %{rows: []} -> :ok
              _ -> raise("Project tenancy migration found invalid foreign keys")
            end
          end,
          migration_foreign_keys: :off
        )
      after
        sql("PRAGMA foreign_keys = ON")
      end
    end)
  end

  defp sql(statement), do: Ecto.Adapters.SQL.query!(repo(), statement, [], log: false)
end
