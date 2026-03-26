defmodule Custyard.Repo.Migrations.CreateInboundRoutes do
  use Ecto.Migration

  def change do
    create table(:inbound_routes) do
      add :lettermint_route_id, :string
      add :callback_token, :string, null: false
      add :organization_id, references(:organizations, on_delete: :delete_all), null: false
      add :project_id, references(:projects, on_delete: :nilify_all)
      add :route_type, :string, null: false, default: "general"

      timestamps(type: :utc_datetime)
    end

    create unique_index(:inbound_routes, [:callback_token])
    create index(:inbound_routes, [:organization_id])
    create index(:inbound_routes, [:project_id])
  end
end
