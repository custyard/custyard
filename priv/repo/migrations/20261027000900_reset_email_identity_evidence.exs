defmodule Custyard.Repo.Migrations.ResetEmailIdentityEvidence do
  use Ecto.Migration

  def change do
    alter table(:email_connections) do
      add :reply_evidence_after_message_id, :integer, null: false, default: 0
    end
  end
end
