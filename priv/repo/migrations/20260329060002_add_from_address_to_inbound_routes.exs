defmodule Custyard.Repo.Migrations.AddFromAddressToInboundRoutes do
  use Ecto.Migration

  def change do
    alter table(:inbound_routes) do
      add :from_address, :string
    end
  end
end
