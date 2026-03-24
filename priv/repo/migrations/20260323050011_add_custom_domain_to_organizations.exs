defmodule Custyard.Repo.Migrations.AddCustomDomainToOrganizations do
  use Ecto.Migration

  def change do
    alter table(:organizations) do
      add :custom_domain, :string
    end

    create unique_index(:organizations, [:custom_domain], where: "custom_domain IS NOT NULL")
  end
end
