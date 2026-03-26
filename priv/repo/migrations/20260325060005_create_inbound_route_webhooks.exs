defmodule Custyard.Repo.Migrations.CreateInboundRouteWebhooks do
  use Ecto.Migration

  def change do
    create table(:inbound_route_webhooks) do
      add :inbound_route_id, references(:inbound_routes, on_delete: :delete_all), null: false
      add :lettermint_webhook_id, :string
      add :endpoint_url, :string
      add :purpose, :string, null: false
      add :enabled, :boolean, default: true, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:inbound_route_webhooks, [:inbound_route_id])
    create unique_index(:inbound_route_webhooks, [:inbound_route_id, :purpose])
  end
end
