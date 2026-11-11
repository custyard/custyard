defmodule Custyard.Repo.Migrations.AddTenantOutboundPause do
  use Ecto.Migration

  def change do
    alter table(:tenants) do
      add :outbound_paused, :boolean, null: false, default: false
    end
  end
end
