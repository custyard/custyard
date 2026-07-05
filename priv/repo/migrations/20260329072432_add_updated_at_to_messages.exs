defmodule Custyard.Repo.Migrations.AddUpdatedAtToMessages do
  use Ecto.Migration

  def up do
    alter table(:messages) do
      add :updated_at, :utc_datetime
    end

    # Backfill existing rows: set updated_at = inserted_at
    execute "UPDATE messages SET updated_at = inserted_at"
  end

  def down do
    alter table(:messages) do
      remove :updated_at
    end
  end
end
