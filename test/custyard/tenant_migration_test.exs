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
      assert [_] = Ecto.Migrator.run(Repo, context.migrations, :up, all: true, log: false)
      assert %{rows: []} = Repo.query!("PRAGMA foreign_key_check")

      for table <-
            ~w(organizations operator_accounts contacts projects intake_sources inbound_routes inbound_channels conversations messages message_attachments tasks prospects portal_credentials) do
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
      %{rows: staff_columns} = Repo.query!("PRAGMA table_info(operator_accounts)")
      refute Enum.any?(staff_columns, &(Enum.at(&1, 1) == "organization_id"))
      assert %{rows: []} = Repo.query!("SELECT * FROM tenants")
      assert %{rows: []} = Repo.query!("SELECT * FROM instance_admins")
    end
  end
end
