defmodule Custyard.Repo.Migrations.CreateContacts do
  use Ecto.Migration

  def change do
    create table(:contacts) do
      add :organization_id, references(:organizations, on_delete: :delete_all), null: false
      add :email, :string, null: false
      add :name, :string
      add :is_admin, :boolean, default: false, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:contacts, [:email])
    create index(:contacts, [:organization_id])
  end
end
