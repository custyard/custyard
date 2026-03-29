defmodule Custyard.Repo.Migrations.AddLettermintProjectIdToOrganizations do
  use Ecto.Migration

  def change do
    alter table(:organizations) do
      add :lettermint_project_id, :string
    end
  end
end
