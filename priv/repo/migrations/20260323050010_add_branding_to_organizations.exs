defmodule Custyard.Repo.Migrations.AddBrandingToOrganizations do
  use Ecto.Migration

  def change do
    alter table(:organizations) do
      add :logo_url, :string
      add :primary_color, :string
      add :secondary_color, :string
    end
  end
end
