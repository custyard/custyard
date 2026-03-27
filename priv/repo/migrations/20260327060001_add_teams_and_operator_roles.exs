defmodule Custyard.Repo.Migrations.AddTeamsAndOperatorRoles do
  use Ecto.Migration

  def change do
    create table(:teams) do
      add :name, :string, null: false
      add :organization_id, references(:organizations, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:teams, [:organization_id, :name])
    create index(:teams, [:organization_id])

    alter table(:operator_accounts) do
      add :role, :string, null: false, default: "admin"
      add :team_id, references(:teams, on_delete: :nilify_all)
    end

    create index(:operator_accounts, [:team_id])
  end
end
