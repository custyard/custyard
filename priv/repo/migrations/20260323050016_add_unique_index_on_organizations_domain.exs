defmodule Custyard.Repo.Migrations.AddUniqueIndexOnOrganizationsDomain do
  use Ecto.Migration

  def change do
    drop index(:organizations, [:domain])
    create unique_index(:organizations, [:domain], where: "domain IS NOT NULL")
  end
end
