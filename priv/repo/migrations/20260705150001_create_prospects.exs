defmodule Custyard.Repo.Migrations.CreateProspects do
  use Ecto.Migration

  def change do
    create table(:prospects) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      # SHA-256 hash of the resume token — plaintext tokens are never persisted
      add :resume_token_hash, :string, null: false
      # Captured prospect email (write-once through the public flow)
      add :email, :string
      # Reply-notification consent; default off (consent is opt-in)
      add :notify_on_reply, :boolean, null: false, default: false
      add :email_captured_at, :utc_datetime
      add :revoked_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    # One prospect per conversation (1:1)
    create unique_index(:prospects, [:conversation_id])
    # Indexed lookup by hashed resume token
    create unique_index(:prospects, [:resume_token_hash])
  end
end
