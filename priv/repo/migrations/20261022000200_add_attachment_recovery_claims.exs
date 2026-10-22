defmodule Custyard.Repo.Migrations.AddAttachmentRecoveryClaims do
  use Ecto.Migration

  def change do
    alter table(:message_attachments) do
      add :descriptor_hash, :string
      add :processing_token, :string
      add :processing_expires_at, :utc_datetime
    end
  end
end
