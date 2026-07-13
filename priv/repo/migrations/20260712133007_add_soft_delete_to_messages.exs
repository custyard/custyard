defmodule Custyard.Repo.Migrations.AddSoftDeleteToMessages do
  use Ecto.Migration

  # GitHub-style soft delete: the original body stays in the row and views
  # render a tombstone. There is deliberately no hard-delete path, so no
  # column removal or data migration accompanies this.
  def change do
    alter table(:messages) do
      add :deleted_at, :utc_datetime
      add :deleted_by_operator_id, references(:operator_accounts, on_delete: :nilify_all)
    end

    create index(:messages, [:deleted_by_operator_id])
  end
end
