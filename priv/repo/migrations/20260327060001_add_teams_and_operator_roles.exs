defmodule Custyard.Repo.Migrations.AddTeamsAndOperatorRoles do
  use Ecto.Migration

  def change do
    create table(:teams) do
      add :name, :string, null: false
      add :organization_id, references(:organizations, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:teams, [:organization_id, :name])
    create index(:teams, [:organization_id])
  end
end
