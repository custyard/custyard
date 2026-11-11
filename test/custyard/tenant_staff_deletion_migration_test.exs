defmodule Custyard.TenantStaffDeletionMigrationTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  defmodule Repo do
    use Ecto.Repo, otp_app: :custyard, adapter: Custyard.Repo.Adapter
  end

  setup_all do
    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    file =
      Application.app_dir(
        :custyard,
        "priv/repo/migrations/20261029024000_restrict_tenant_staff_deletion.exs"
      )

    try do
      [{module, _}] = Code.compile_file(file)
      %{migration: module}
    after
      Code.put_compiler_option(:ignore_module_conflict, previous)
    end
  end

  for backend <- [:sqlite, :turso] do
    @tag backend: backend
    test "#{backend}: fresh baseline declares staff tenant deletion restriction", c do
      start_repo(c)
      create_baseline(false)
      %{rows: keys} = Repo.query!("PRAGMA foreign_key_list(staff_accounts)")
      assert Enum.any?(keys, &(Enum.at(&1, 2) == "tenants" and Enum.at(&1, 6) == "RESTRICT"))
      seed_staff()
      assert {:error, _} = Repo.query("DELETE FROM tenants WHERE id = 1")
      assert %{rows: [[1]]} = Repo.query!("SELECT tenant_id FROM staff_accounts WHERE id = 1")
      assert %{rows: []} = Repo.query!("PRAGMA foreign_key_check")
    end

    @tag backend: backend
    test "#{backend}: forward migration restricts legacy deletion without rewriting staff", c do
      start_repo(c)
      create_baseline(true)
      seed_staff()
      assert :ok = Ecto.Migrator.up(Repo, 20_261_029_024_000, c.migration, log: false)
      assert {:error, error} = Repo.query("DELETE FROM tenants WHERE id = 1")
      assert Exception.message(error) =~ "cannot delete a tenant with staff accounts"

      assert %{rows: [[1, "original-session"]]} =
               Repo.query!("SELECT tenant_id, session_claim FROM staff_accounts WHERE id = 1")

      assert %{rows: []} = Repo.query!("PRAGMA foreign_key_check")

      Repo.query!(
        "INSERT INTO tenants (id, name, slug, inserted_at, updated_at) VALUES (2, 'Empty', 'empty', '2026-10-29 00:00:00', '2026-10-29 00:00:00')"
      )

      assert %{num_rows: 1} = Repo.query!("DELETE FROM tenants WHERE id = 2")
      assert :ok = Ecto.Migrator.down(Repo, 20_261_029_024_000, c.migration, log: false)

      assert %{rows: []} =
               Repo.query!(
                 "SELECT name FROM sqlite_master WHERE name = 'tenants_restrict_staff_deletion'"
               )

      assert %{rows: [[1]]} = Repo.query!("SELECT tenant_id FROM staff_accounts WHERE id = 1")
    end
  end

  defp start_repo(c) do
    database = Path.join(c.tmp_dir, "staff-delete.db")

    opts =
      case c.backend do
        :sqlite ->
          [database: database]

        :turso ->
          server = start_supervised!({Custyard.TursoTestServer, database: database})
          [turso_url: Custyard.TursoTestServer.url(server)]
      end

    start_supervised!({Repo, [pool_size: 2, log: false] ++ opts})
  end

  defp create_baseline(legacy?) do
    sql = Application.app_dir(:custyard, "priv/repo/schema.sql") |> File.read!()

    sql =
      if legacy?,
        do:
          String.replace(
            sql,
            "tenant_id INTEGER NOT NULL REFERENCES tenants(id) ON DELETE RESTRICT",
            "tenant_id INTEGER NOT NULL REFERENCES tenants(id) ON DELETE SET NULL"
          ),
        else: sql

    sql
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.each(&Repo.query!/1)
  end

  defp seed_staff do
    Repo.query!(
      "INSERT INTO tenants (id, name, slug, inserted_at, updated_at) VALUES (1, 'Tenant', 'tenant', '2026-10-29 00:00:00', '2026-10-29 00:00:00')"
    )

    Repo.query!(
      "INSERT INTO staff_accounts (id, tenant_id, email, session_claim, inserted_at, updated_at) VALUES (1, 1, 'staff@example.com', 'original-session', '2026-10-29 00:00:00', '2026-10-29 00:00:00')"
    )
  end
end
