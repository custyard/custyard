defmodule Custyard.DraftMigrationTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @draft_version 20_261_029_022_000

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

  setup context do
    path = Path.join(context.tmp_dir, "drafts.db")

    opts =
      case context.backend do
        :sqlite ->
          [database: path]

        :turso ->
          server = start_supervised!({Custyard.TursoTestServer, database: path})
          [turso_url: Custyard.TursoTestServer.url(server)]
      end

    start_supervised!({Repo, [pool_size: 2, log: false] ++ opts})
    Ecto.Migrator.run(Repo, context.migrations, :up, to: 20_261_029_021_000, log: false)
    seed_tenants()

    applied =
      Ecto.Migrator.run(Repo, context.migrations, :up, to: @draft_version, log: false)

    %{applied: applied}
  end

  for backend <- [:sqlite, :turso] do
    @tag backend: backend
    test "#{backend}: rejects foreign staff, thread and sending channel on insert or update" do
      assert {:error, _} = insert_draft(1, 2, 1, 1)
      assert {:error, _} = insert_draft(1, 1, 2, nil)
      assert {:error, _} = insert_draft(1, 1, 1, 2)
      assert %{rows: [[0]]} = Repo.query!("SELECT COUNT(*) FROM staff_message_drafts")

      assert {:ok, _} = insert_draft(1, 1, 1, 1)

      for update <- ["staff_account_id = 2", "thread_id = 2", "reply_channel_id = 2"] do
        assert {:error, _} = Repo.query("UPDATE staff_message_drafts SET #{update} WHERE id = 1")
      end

      assert %{rows: [[1, 1, 1]]} =
               Repo.query!(
                 "SELECT staff_account_id, thread_id, reply_channel_id FROM staff_message_drafts"
               )

      assert %{rows: []} = Repo.query!("PRAGMA foreign_key_check")
    end

    @tag backend: backend
    test "#{backend}: moving staff to another tenant purges only their private drafts" do
      insert_drafts!()
      Repo.query!("UPDATE staff_accounts SET tenant_id = 2 WHERE id = 1")
      assert %{rows: [[2]]} = Repo.query!("SELECT id FROM staff_message_drafts")
      assert %{rows: [[2]]} = Repo.query!("SELECT tenant_id FROM staff_accounts WHERE id = 1")
      assert %{rows: []} = Repo.query!("PRAGMA foreign_key_check")
    end

    @tag backend: backend
    test "#{backend}: moving a thread to another tenant purges only its private drafts" do
      insert_drafts!()
      Repo.query!("UPDATE threads SET tenant_id = 2 WHERE id = 1")
      assert %{rows: [[2]]} = Repo.query!("SELECT id FROM staff_message_drafts")
      assert %{rows: [[2]]} = Repo.query!("SELECT tenant_id FROM threads WHERE id = 1")
      assert %{rows: []} = Repo.query!("PRAGMA foreign_key_check")
    end

    @tag backend: backend
    test "#{backend}: moving a channel clears the reviewed sender and invalidates the draft version" do
      insert_drafts!()
      Repo.query!("UPDATE staff_message_drafts SET lock_version = 5 WHERE id = 1")
      Repo.query!("UPDATE inbound_channels SET tenant_id = 2, inbound_route_id = 2 WHERE id = 1")

      assert %{rows: [[nil, 6, "Reply 1", "Note 1"], [2, 1, "Reply 2", "Note 2"]]} =
               Repo.query!(
                 "SELECT reply_channel_id, lock_version, reply_text, note_text FROM staff_message_drafts ORDER BY id"
               )

      assert %{rows: []} = Repo.query!("PRAGMA foreign_key_check")
    end

    @tag backend: backend
    test "#{backend}: migration rollback removes its table and triggers while preserving parent records",
         context do
      assert context.applied == [@draft_version]
      insert_drafts!()

      assert [@draft_version] =
               Ecto.Migrator.run(Repo, context.migrations, :down,
                 to: @draft_version,
                 log: false
               )

      assert %{rows: []} =
               Repo.query!(
                 "SELECT name FROM sqlite_master WHERE name = 'staff_message_drafts' OR name LIKE 'staff_draft_scope_%' OR name IN ('staff_accounts_purge_private_drafts', 'threads_purge_private_drafts', 'inbound_channels_clear_private_draft_sender')"
               )

      for table <- ~w(staff_accounts threads inbound_channels) do
        assert %{rows: [[2]]} = Repo.query!("SELECT COUNT(*) FROM #{table}")
      end

      assert %{rows: []} = Repo.query!("PRAGMA foreign_key_check")

      assert [@draft_version] =
               Ecto.Migrator.run(Repo, context.migrations, :up,
                 to: @draft_version,
                 log: false
               )

      assert {:error, _} = insert_draft(1, 1, 1, 2)
      assert {:ok, _} = insert_draft(1, 1, 1, 1)
    end
  end

  defp seed_tenants do
    for id <- [1, 2] do
      Repo.query!(
        "INSERT INTO tenants (id, name, slug, inserted_at, updated_at) VALUES (?, 'Tenant', ?, '2026-10-29 00:00:00', '2026-10-29 00:00:00')",
        [id, "tenant-#{id}"]
      )

      Repo.query!(
        "INSERT INTO staff_accounts (id, tenant_id, email, inserted_at, updated_at) VALUES (?, ?, ?, '2026-10-29 00:00:00', '2026-10-29 00:00:00')",
        [id, id, "staff-#{id}@example.com"]
      )

      Repo.query!(
        "INSERT INTO threads (id, tenant_id, subject, inserted_at, updated_at) VALUES (?, ?, 'Existing thread', '2026-10-29 00:00:00', '2026-10-29 00:00:00')",
        [id, id]
      )

      Repo.query!(
        "INSERT INTO inbound_routes (id, tenant_id, callback_token, inserted_at, updated_at) VALUES (?, ?, ?, '2026-10-29 00:00:00', '2026-10-29 00:00:00')",
        [id, id, "callback-#{id}"]
      )

      Repo.query!(
        "INSERT INTO inbound_channels (id, tenant_id, inbound_route_id, public_address, ingress_local, ingress_token, inserted_at, updated_at) VALUES (?, ?, ?, ?, 'support', ?, '2026-10-29 00:00:00', '2026-10-29 00:00:00')",
        [id, id, id, "support-#{id}@example.com", "ingress-#{id}"]
      )
    end
  end

  defp insert_draft(id, staff_id, thread_id, channel_id) do
    Repo.query(
      "INSERT INTO staff_message_drafts (id, staff_account_id, thread_id, reply_channel_id, reply_text, note_text, inserted_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, '2026-10-29 00:00:00', '2026-10-29 00:00:00')",
      [id, staff_id, thread_id, channel_id, "Reply #{id}", "Note #{id}"]
    )
  end

  defp insert_drafts! do
    for id <- [1, 2], do: assert({:ok, _} = insert_draft(id, id, id, id))
  end
end
