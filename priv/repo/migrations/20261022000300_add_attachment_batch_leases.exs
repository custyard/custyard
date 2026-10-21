defmodule Custyard.Repo.Migrations.AddAttachmentBatchLeases do
  use Ecto.Migration

  def change do
    alter table(:message_attachments) do
      add :batch_processing_token, :string
      add :batch_processing_expires_at, :utc_datetime
    end
  end
end
