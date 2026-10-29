defmodule Custyard.Attachments.ScanMigrationTest do
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
          [{module, _}] = Code.compile_file(file)
          {version, module}
        end)

      {:ok, migrations: migrations}
    after
      Code.put_compiler_option(:ignore_module_conflict, previous)
    end
  end

  for backend <- [:sqlite, :turso] do
    @tag backend: backend
    test "#{backend}: quarantine upgrade and rollback preserve files and terminal blob verdicts",
         context do
      database = Path.join(context.tmp_dir, "scan-migration.db")

      opts =
        case context.backend do
          :sqlite ->
            [database: database]

          :turso ->
            server = start_supervised!({Custyard.TursoTestServer, database: database})
            [turso_url: Custyard.TursoTestServer.url(server)]
        end

      start_supervised!({Repo, [pool_size: 2, log: false] ++ opts})
      Ecto.Migrator.run(Repo, context.migrations, :up, to: 20_261_029_022_000, log: false)
      seed_files()

      assert [20_261_029_023_000] =
               Ecto.Migrator.run(Repo, context.migrations, :up,
                 to: 20_261_029_023_000,
                 log: false
               )

      assert %{rows: [[1, "pending", nil], [2, "pending", nil], [3, "pending", nil]]} =
               Repo.query!(
                 "SELECT id, scan_status, scanned_at FROM message_attachments ORDER BY id"
               )

      Repo.query!("UPDATE message_attachments SET scan_status = 'clean'")
      Repo.query!("UPDATE message_attachments SET scan_status = 'infected' WHERE id = 1")

      assert %{rows: [[1, "infected"], [2, "infected"], [3, "clean"]]} =
               Repo.query!("SELECT id, scan_status FROM message_attachments ORDER BY id")

      insert_file(4, 1, 1, 2, ", scan_status", ", 'clean'")
      Repo.query!("UPDATE message_attachments SET scan_status = 'clean' WHERE id = 1")

      assert %{rows: [["infected"], ["infected"]]} =
               Repo.query!("SELECT scan_status FROM message_attachments WHERE id IN (1, 4)")

      assert [20_261_029_023_000] =
               Ecto.Migrator.run(Repo, context.migrations, :down,
                 to: 20_261_029_023_000,
                 log: false
               )

      assert %{rows: [[4]]} = Repo.query!("SELECT count(*) FROM message_attachments")
      assert %{rows: []} = Repo.query!("PRAGMA foreign_key_check")
      %{rows: columns} = Repo.query!("PRAGMA table_info(message_attachments)")
      refute Enum.any?(columns, &(Enum.at(&1, 1) in ~w(scan_status scanned_at scan_token)))
    end
  end

  defp seed_files do
    for id <- [1, 2] do
      Repo.query!(
        "INSERT INTO tenants (id, name, slug, inserted_at, updated_at) VALUES (?, 'Tenant', ?, '2026-10-29 00:00:00', '2026-10-29 00:00:00')",
        [id, "tenant-#{id}"]
      )

      Repo.query!(
        "INSERT INTO threads (id, tenant_id, subject, inserted_at, updated_at) VALUES (?, ?, 'Thread', '2026-10-29 00:00:00', '2026-10-29 00:00:00')",
        [id, id]
      )

      Repo.query!(
        "INSERT INTO messages (id, tenant_id, thread_id, source, body, inserted_at) VALUES (?, ?, ?, 'email', 'Body', '2026-10-29 00:00:00')",
        [id, id, id]
      )
    end

    insert_file(1, 1, 1, 0)
    insert_file(2, 1, 1, 1)
    insert_file(3, 2, 2, 0)
  end

  defp insert_file(id, tenant, message, position, columns \\ "", values \\ "") do
    Repo.query!(
      "INSERT INTO message_attachments (id, tenant_id, message_id, position, state, sha256, storage_path, size, inserted_at, updated_at#{columns}) VALUES (?, ?, ?, ?, 'fetched', ?, ?, 5, '2026-10-29 00:00:00', '2026-10-29 00:00:00'#{values})",
      [
        id,
        tenant,
        message,
        position,
        String.duplicate("a", 64),
        "#{tenant}/aa/#{String.duplicate("a", 64)}"
      ]
    )
  end
end
