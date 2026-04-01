defmodule Custyard.Repo.Migrations.AddUpdatedAtToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :updated_at, :utc_datetime
    end

    # Backfill existing rows: set updated_at = inserted_at
    execute "UPDATE messages SET updated_at = inserted_at", ""
  end
end
