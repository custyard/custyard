defmodule Custyard.TenantMigrationTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  defmodule Repo do
    use Ecto.Repo, otp_app: :custyard, adapter: Custyard.Repo.Adapter
  end

  setup_all do
    previous = Code.get_compiler_option(:ignore_module_conflict)
    Code.put_compiler_option(:ignore_module_conflict, true)

    try do
      migrations =
        Application.app_dir(:custyard, "priv/repo/migrations/*.exs")
        |> Path.wildcard()
        |> Enum.map(fn file ->
          version = file |> Path.basename() |> String.split("_") |> hd() |> String.to_integer()
          [{module, _binary}] = Code.compile_file(file)
          {version, module}
        end)

      {:ok, migrations: migrations}
    after
      Code.put_compiler_option(:ignore_module_conflict, previous)
    end
  end

  for backend <- [:sqlite, :turso] do
    @tag backend: backend
    test "#{backend}: fresh baseline enforces explicit tenant ownership without legacy organization settings",
         context do
      opts =
        case context.backend do
          :sqlite ->
            [database: Path.join(context.tmp_dir, "migration.db")]

          :turso ->
            server =
              start_supervised!(
                {Custyard.TursoTestServer, database: Path.join(context.tmp_dir, "migration.db")}
              )

            [turso_url: Custyard.TursoTestServer.url(server)]
        end

      start_supervised!({Repo, [pool_size: 2, log: false] ++ opts})

      assert Ecto.Migrator.run(Repo, context.migrations, :up, all: true, log: false) ==
               Enum.map(context.migrations, &elem(&1, 0))

      assert %{rows: []} = Repo.query!("PRAGMA foreign_key_check")

      for table <-
            ~w(organizations staff_accounts contacts projects intake_sources inbound_routes inbound_channels threads messages message_attachments tasks prospects portal_credentials) do
        %{rows: columns} = Repo.query!("PRAGMA table_info(#{table})")
        tenant = Enum.find(columns, &(Enum.at(&1, 1) == "tenant_id"))
        assert tenant, "#{table} must have explicit tenant ownership"
        assert Enum.at(tenant, 3) == 1
        assert Enum.at(tenant, 4) == nil
      end

      %{rows: org_columns} = Repo.query!("PRAGMA table_info(organizations)")
      names = Enum.map(org_columns, &Enum.at(&1, 1))

      for removed <-
            ~w(token intake_key logo_url primary_color secondary_color custom_domain lettermint_project_id) do
        refute removed in names
      end

      assert "identity_kind" in names
      assert "identity_value" in names
      assert "public_id" in names
      %{rows: staff_columns} = Repo.query!("PRAGMA table_info(staff_accounts)")
      refute Enum.any?(staff_columns, &(Enum.at(&1, 1) == "organization_id"))
      assert %{rows: []} = Repo.query!("SELECT * FROM tenants")
      assert %{rows: []} = Repo.query!("SELECT * FROM instance_admins")
    end

    @tag backend: backend
    test "#{backend}: message author migration preserves history and tenant boundaries",
         context do
      opts =
        case context.backend do
          :sqlite ->
            [database: Path.join(context.tmp_dir, "authors.db")]

          :turso ->
            server =
              start_supervised!(
                {Custyard.TursoTestServer, database: Path.join(context.tmp_dir, "authors.db")}
              )

            [turso_url: Custyard.TursoTestServer.url(server)]
        end

      start_supervised!({Repo, [pool_size: 2, log: false] ++ opts})
      Ecto.Migrator.run(Repo, context.migrations, :up, to: 20_261_029_010_000, log: false)

      for id <- [1, 2] do
        Repo.query!(
          "INSERT INTO tenants (id, name, slug, inserted_at, updated_at) VALUES (?, 'Tenant', ?, '2026-10-29 00:00:00', '2026-10-29 00:00:00')",
          [id, "tenant-#{id}"]
        )

        Repo.query!(
          "INSERT INTO staff_accounts (id, tenant_id, email, inserted_at, updated_at) VALUES (?, ?, 'staff@example.com', '2026-10-29 00:00:00', '2026-10-29 00:00:00')",
          [id, id]
        )
      end

      Repo.query!(
        "INSERT INTO threads (id, tenant_id, subject, inserted_at, updated_at) VALUES (1, 1, 'Historical thread', '2026-10-29 00:00:00', '2026-10-29 00:00:00')"
      )

      Repo.query!(
        "INSERT INTO messages (id, tenant_id, thread_id, source, body, inserted_at) VALUES (1, 1, 1, 'staff', 'Historical reply', '2026-10-29 00:00:00')"
      )

      assert [20_261_029_020_000] =
               Ecto.Migrator.run(Repo, context.migrations, :up,
                 to: 20_261_029_020_000,
                 log: false
               )

      assert %{rows: [["Historical reply", nil]]} =
               Repo.query!("SELECT body, author_staff_id FROM messages WHERE id = 1")

      assert {:error, _} = Repo.query("UPDATE messages SET author_staff_id = 2 WHERE id = 1")
      Repo.query!("UPDATE messages SET author_staff_id = 1 WHERE id = 1")
      assert {:error, _} = Repo.query("UPDATE staff_accounts SET tenant_id = 2 WHERE id = 1")
      Repo.query!("DELETE FROM staff_accounts WHERE id = 1")

      assert %{rows: [["Historical reply", nil]]} =
               Repo.query!("SELECT body, author_staff_id FROM messages WHERE id = 1")

      assert [20_261_029_020_000] =
               Ecto.Migrator.run(Repo, context.migrations, :down,
                 to: 20_261_029_020_000,
                 log: false
               )

      assert %{rows: [["Historical reply"]]} =
               Repo.query!("SELECT body FROM messages WHERE id = 1")

      assert %{rows: []} = Repo.query!("PRAGMA foreign_key_check")
    end

    @tag backend: backend
    test "#{backend}: customer public IDs preserve existing records and relationships", context do
      opts =
        case context.backend do
          :sqlite ->
            [database: Path.join(context.tmp_dir, "upgrade.db")]

          :turso ->
            server =
              start_supervised!(
                {Custyard.TursoTestServer, database: Path.join(context.tmp_dir, "upgrade.db")}
              )

            [turso_url: Custyard.TursoTestServer.url(server)]
        end

      start_supervised!({Repo, [pool_size: 2, log: false] ++ opts})
      [{baseline, _} | _] = context.migrations

      assert [^baseline] =
               Ecto.Migrator.run(Repo, context.migrations, :up, to: baseline, log: false)

      Repo.query!(
        "INSERT INTO tenants (id, name, slug, inserted_at, updated_at) VALUES (1, 'Tenant', 'tenant', '2026-10-29 00:00:00', '2026-10-29 00:00:00')"
      )

      for id <- [1, 2] do
        Repo.query!(
          "INSERT INTO organizations (id, name, tenant_id, identity_value, inserted_at, updated_at) VALUES (?, 'Customer', 1, ?, '2026-10-29 00:00:00', '2026-10-29 00:00:00')",
          [id, "customer-#{id}"]
        )
      end

      Repo.query!(
        "INSERT INTO contacts (id, organization_id, tenant_id, email, inserted_at, updated_at) VALUES (1, 1, 1, 'contact@example.com', '2026-10-29 00:00:00', '2026-10-29 00:00:00')"
      )

      Repo.query!(
        "UPDATE organizations SET identity_kind = 'email', identity_value = 'contact@example.com' WHERE id = 1"
      )

      Ecto.Migrator.run(Repo, context.migrations, :up, all: true, log: false)

      assert %{rows: [[1, first], [2, second]]} =
               Repo.query!("SELECT id, public_id FROM organizations ORDER BY id")

      assert {:ok, _} = Ecto.UUID.cast(first)
      assert {:ok, _} = Ecto.UUID.cast(second)
      assert first != second
      assert %{rows: [[1, 1]]} = Repo.query!("SELECT id, organization_id FROM contacts")

      assert %{rows: [[1, 1], [2, nil]]} =
               Repo.query!("SELECT id, default_contact_id FROM organizations ORDER BY id")

      assert {:error, _} =
               Repo.query("UPDATE organizations SET default_contact_id = 1 WHERE id = 2")

      assert %{rows: []} = Repo.query!("PRAGMA foreign_key_check")
      assert {:error, _} = Repo.query("UPDATE organizations SET public_id = NULL WHERE id = 1")

      assert {:error, _} =
               Repo.query("UPDATE organizations SET public_id = ? WHERE id = 2", [first])
    end
  end
end
