defmodule Custyard.Repo.Migrations.CreateMessages do
  use Ecto.Migration

  def change do
    create table(:messages) do
      add :conversation_id, references(:conversations, on_delete: :delete_all), null: false
      add :source, :string, null: false
      add :sender_email, :string
      add :body, :text, null: false
      add :is_internal_note, :boolean, default: false, null: false
      add :message_id, :string
      add :in_reply_to, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:messages, [:conversation_id])
    create index(:messages, [:message_id])
  end
end
