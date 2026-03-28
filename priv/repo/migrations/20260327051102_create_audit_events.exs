defmodule Custyard.Repo.Migrations.CreateAuditEvents do
  use Ecto.Migration

  def change do
    create table(:audit_events) do
      add :conversation_id, references(:conversations, on_delete: :nothing)
      add :event_type, :string, null: false
      add :source, :string, null: false
      add :message_id, :string
      add :payload, :map
      add :organization_id, references(:organizations, on_delete: :nothing)
      add :project_id, references(:projects, on_delete: :nothing)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:audit_events, [:conversation_id])
    create index(:audit_events, [:organization_id])
    create index(:audit_events, [:message_id])
    create index(:audit_events, [:inserted_at])
  end
end
