defmodule Custyard.TenantMigrationTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir
  @baseline 20_261_025_000_000
  @tables ~w(organizations operator_accounts contacts projects intake_sources inbound_routes inbound_route_webhooks inbound_channels conversations messages message_attachments tasks prospects inbound_channel_rejections)

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
    test "#{backend}: seeded tenant upgrade and rollback preserve customer and public history",
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
      Ecto.Migrator.run(Repo, context.migrations, :up, to: @baseline, log: false)
      seed_history()
      original = snapshot()
      sequences = sequence_snapshot()

      Ecto.Migrator.run(Repo, context.migrations, :up, all: true, log: false)
      assert_original_history(original, sequences)

      for table <-
            ~w(organizations conversations projects intake_sources inbound_routes inbound_channels inbound_channel_rejections) do
        assert %{rows: [[1]]} = Repo.query!("SELECT DISTINCT tenant_id FROM #{table}")
      end

      assert %{rows: [[nil, 41]]} =
               Repo.query!("SELECT tenant_id,organization_id FROM operator_accounts WHERE id=42")

      Ecto.Migrator.run(Repo, context.migrations, :down, to_exclusive: @baseline, log: false)
      assert_original_history(original, sequences)

      %{rows: project_columns} = Repo.query!("PRAGMA table_info(projects)")
      refute Enum.any?(project_columns, &(Enum.at(&1, 1) == "tenant_id"))

      for table <- ~w(inbound_routes inbound_channels inbound_channel_rejections) do
        %{rows: columns} = Repo.query!("PRAGMA table_info(#{table})")
        organization = Enum.find(columns, &(Enum.at(&1, 1) == "organization_id"))
        assert Enum.at(organization, 3) == 1
      end
    end
  end

  defp seed_history do
    records = [
      {"organizations",
       %{id: 41, name: "Customer", domain: "fixture.example", token: "portal-token-preserved"}},
      {"operator_accounts",
       %{
         id: 42,
         email: "operator@fixture.example",
         role: "admin",
         organization_id: 41,
         session_claim: "session-claim-preserved"
       }},
      {"contacts", %{id: 43, email: "alice@fixture.example", organization_id: 41}},
      {"projects", %{id: 44, title: "Customer project", organization_id: 41}},
      {"intake_sources", %{id: 45, key: "fixture-intake", name: "Public intake"}},
      {"inbound_routes",
       %{
         id: 46,
         organization_id: 41,
         project_id: 44,
         callback_token: "callback-preserved",
         source: "lettermint"
       }},
      {"inbound_route_webhooks", %{id: 47, inbound_route_id: 46, purpose: "sender_matching"}},
      {"inbound_channels",
       %{
         id: 48,
         inbound_route_id: 46,
         organization_id: 41,
         public_address: "support@fixture.example",
         ingress_local: "support",
         ingress_token: "ingress-preserved",
         state: "active"
       }},
      {"conversations",
       %{
         id: 49,
         organization_id: 41,
         contact_id: 43,
         project_id: 44,
         inbound_channel_id: 48,
         subject: "Customer thread",
         source: "lettermint"
       }},
      {"conversations",
       %{
         id: 50,
         subject: "Public thread",
         source: "public_intake",
         intake_source_key: "fixture-intake"
       }},
      {"messages",
       %{
         id: 51,
         conversation_id: 49,
         source: "email",
         body: "Customer body preserved",
         inbound_channel_id: 48,
         message_id: "<customer@fixture.example>"
       }},
      {"messages",
       %{id: 52, conversation_id: 50, source: "prospect", body: "Public body preserved"}},
      {"message_attachments",
       %{
         id: 53,
         message_id: 51,
         state: "fetched",
         filename: "fixture.txt",
         storage_path: "aa/fixture"
       }},
      {"tasks",
       %{
         id: 54,
         conversation_id: 49,
         project_id: 44,
         organization_id: 41,
         title: "Shared legacy task",
         portal_visible: true
       }},
      {"tasks",
       %{id: 55, conversation_id: 50, title: "Private legacy task", portal_visible: false}},
      {"prospects",
       %{
         id: 56,
         conversation_id: 50,
         access_token_hash: "public-token-hash-preserved",
         email: "prospect@fixture.example",
         notify_on_reply: true
       }},
      {"inbound_channel_rejections",
       %{
         id: 57,
         inbound_route_id: 46,
         inbound_channel_id: 48,
         organization_id: 41,
         classification: "auto_response"
       }}
    ]

    for {table, attrs} <- records do
      %{rows: columns} = Repo.query!("PRAGMA table_info(#{table})")
      fields = Enum.map(columns, &Enum.at(&1, 1))

      attrs =
        Enum.reduce([:inserted_at, :updated_at], attrs, fn key, attrs ->
          if Atom.to_string(key) in fields,
            do: Map.put(attrs, key, "2026-10-26T12:00:00"),
            else: attrs
        end)

      {keys, values} = attrs |> Enum.sort() |> Enum.unzip()
      placeholders = Enum.map_join(keys, ",", fn _ -> "?" end)

      Repo.query!(
        "INSERT INTO #{table} (#{Enum.join(keys, ",")}) VALUES (#{placeholders})",
        values
      )
    end

    # Deleted high IDs must remain unavailable after rebuilding a table.
    for table <- ~w(inbound_routes inbound_channels inbound_channel_rejections tasks),
        do: Repo.query!("UPDATE sqlite_sequence SET seq=999 WHERE name=?", [table])
  end

  defp snapshot do
    Map.new(@tables, fn table ->
      %{columns: columns, rows: rows} = Repo.query!("SELECT * FROM #{table} ORDER BY id")
      {table, Enum.map(rows, &Map.new(Enum.zip(columns, &1)))}
    end)
  end

  defp sequence_snapshot do
    %{rows: rows} = Repo.query!("SELECT name,seq FROM sqlite_sequence")
    rows |> Map.new(fn [name, seq] -> {name, seq} end) |> Map.take(@tables)
  end

  defp assert_original_history(original, sequences) do
    actual = snapshot()

    for table <- @tables do
      assert length(actual[table]) == length(original[table]), "#{table} row count changed"

      for {old, new} <- Enum.zip(original[table], actual[table]),
          do: assert(Map.take(new, Map.keys(old)) == old, "#{table} original fields changed")
    end

    assert sequence_snapshot() == sequences
    assert %{rows: []} = Repo.query!("PRAGMA foreign_key_check")
  end
end
