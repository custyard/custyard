defmodule Custyard.Repo.Migrations.AddSourceToInboundRoutes do
  use Ecto.Migration

  @doc """
  Adds `source` field to inbound_routes table.

  This is a security fix: the source (webhook adapter) should be stored on the
  route itself, not accepted from the request body. This prevents attackers from
  selecting adapters with weaker or no signature verification.

  Default is :lettermint for backward compatibility with existing routes.
  """
  def change do
    alter table(:inbound_routes) do
      add :source, :string, default: "lettermint", null: false
    end

    # Index for potential filtering by source
    create index(:inbound_routes, [:source])
  end
end
