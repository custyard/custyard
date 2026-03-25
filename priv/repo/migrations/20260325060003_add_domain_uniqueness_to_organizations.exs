defmodule Custyard.Repo.Migrations.AddDomainUniquenessToOrganizations do
  use Ecto.Migration

  def change do
    # Unique domain where domain is not NULL
    # SQLite supports partial indexes with WHERE clauses
    create unique_index(:organizations, [:domain], where: "domain IS NOT NULL")
  end
end
