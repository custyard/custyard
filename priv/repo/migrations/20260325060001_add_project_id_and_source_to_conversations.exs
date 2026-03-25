defmodule Custyard.Repo.Migrations.AddProjectIdAndSourceToConversations do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :project_id, references(:projects, on_delete: :nilify_all)
      add :source, :string, default: "email"
    end

    # Allow nullable organization_id for disambiguation-state conversations
    # SQLite doesn't support ALTER COLUMN, so we leave organization_id as-is
    # and handle nullability at the application level

    create index(:conversations, [:project_id])
    create index(:conversations, [:source])
  end
end
