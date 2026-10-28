defmodule Custyard.Repo.Migrations.AddEmailRoundtripEvidence do
  use Ecto.Migration

  def change do
    alter table(:email_connections) do
      add :latest_received_conversation_id, references(:conversations, on_delete: :nilify_all)
      add :last_returning_reply_at, :utc_datetime
    end
  end
end
