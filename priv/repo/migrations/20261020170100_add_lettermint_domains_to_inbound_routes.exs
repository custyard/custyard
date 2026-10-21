defmodule Custyard.Repo.Migrations.AddLettermintDomainsToInboundRoutes do
  use Ecto.Migration

  def change do
    alter table(:inbound_routes) do
      add :lettermint_route_domain, :string
      add :lettermint_inbound_address, :string
      add :lettermint_custom_domain, :string
      add :lettermint_custom_domain_verified_at, :utc_datetime
    end
  end
end
