defmodule Custyard.Repo.Migrations.AddSieveHeaderMappingsToSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      # Sieve header mappings as JSON
      # Format: %{header_name => %{property => property_name, mapping => %{value => property_value}}}
      # Example: %{"X-Customer-Tier" => %{property: "tier", mapping: %{"ent" => "enterprise", "std" => "standard"}}}
      add :sieve_header_mappings, :map, default: %{}
    end
  end
end
