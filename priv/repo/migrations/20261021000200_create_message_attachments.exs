defmodule Custyard.Repo.Migrations.CreateMessageAttachments do
  use Ecto.Migration

  # spec-inbound-channels D9: attachments fetched from the provider's signed
  # URLs into content-addressed files. The signed URL itself is never stored;
  # `storage_path` is relative to the attachment directory and derived from
  # the content hash, never from the declared filename.
  def change do
    create table(:message_attachments) do
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      add :filename, :string
      add :content_type, :string
      add :sniffed_type, :string
      add :size, :bigint
      add :sha256, :string, size: 64
      add :storage_path, :string
      add :content_id, :string
      # fetched | skipped | failed
      add :state, :string, null: false
      # over_limit | suspect | fetch_failed | too_large | unsupported
      add :skip_reason, :string

      timestamps(type: :utc_datetime)
    end

    create index(:message_attachments, [:message_id])
    create index(:message_attachments, [:sha256])
  end
end
