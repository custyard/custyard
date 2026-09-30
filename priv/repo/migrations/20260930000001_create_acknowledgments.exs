defmodule Custyard.Repo.Migrations.CreateAcknowledgments do
  use Ecto.Migration

  def change do
    create table(:acknowledgment_organization_bindings) do
      add :source, :string, null: false
      add :source_organization_id, :string, null: false
      add :organization_id, references(:organizations, on_delete: :restrict), null: false
      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:acknowledgment_organization_bindings, [:source, :source_organization_id])

    create table(:acknowledgments) do
      add :schema_version, :integer, null: false

      for field <- [
            :source,
            :submission_id,
            :source_organization_id,
            :actor_id,
            :actor_role,
            :actor_type,
            :statement_key,
            :statement_version,
            :statement_hash,
            :acknowledged_at
          ] do
        add field, :string, null: false
      end

      add :statement_text, :text, null: false
      add :received_at, :utc_datetime_usec, null: false
      add :organization_id, references(:organizations, on_delete: :restrict), null: false
    end

    create unique_index(:acknowledgments, [:source, :submission_id])
    create index(:acknowledgments, [:organization_id, :received_at])
  end
end
