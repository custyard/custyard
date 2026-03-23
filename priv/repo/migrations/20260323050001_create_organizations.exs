defmodule Custyard.Repo.Migrations.CreateOrganizations do
  use Ecto.Migration

  def change do
    create table(:organizations) do
      add :name, :string, null: false
      add :domain, :string
      add :tier, :string, default: "standard", null: false
      add :token, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:organizations, [:token])
    create index(:organizations, [:domain])
  end
end
