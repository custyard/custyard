defmodule Custyard.Repo.Migrations.AddAttachmentPositions do
  use Ecto.Migration

  def up do
    alter table(:message_attachments) do
      add :position, :integer
    end

    execute("""
    UPDATE message_attachments SET position = (
      SELECT COUNT(*) - 1 FROM message_attachments AS previous
      WHERE previous.message_id = message_attachments.message_id
        AND previous.id <= message_attachments.id
    )
    """)

    create unique_index(:message_attachments, [:message_id, :position])
  end

  def down do
    drop index(:message_attachments, [:message_id, :position])

    alter table(:message_attachments) do
      remove :position
    end
  end
end
