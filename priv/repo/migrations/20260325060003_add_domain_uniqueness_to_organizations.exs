defmodule Custyard.Repo.Migrations.AddDomainUniquenessToOrganizations do
  use Ecto.Migration

  def change do
    # Drop the existing non-unique domain index first
    drop_if_exists index(:organizations, [:domain], name: :organizations_domain_index)

    # Create unique partial index: domain must be unique where not NULL
    # Use explicit name to avoid collision with the dropped index
    create_if_not_exists unique_index(:organizations, [:domain],
      name: :organizations_domain_unique_index,
      where: "domain IS NOT NULL"
    )
  end
end
