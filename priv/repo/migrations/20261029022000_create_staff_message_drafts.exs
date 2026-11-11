defmodule Custyard.Repo.Migrations.CreateStaffMessageDrafts do
  use Ecto.Migration

  def change do
    create table(:staff_message_drafts) do
      add :staff_account_id, references(:staff_accounts, on_delete: :delete_all), null: false
      add :thread_id, references(:threads, on_delete: :delete_all), null: false
      add :reply_text, :text, null: false, default: ""
      add :note_text, :text, null: false, default: ""
      add :reply_cc, :text, null: false, default: ""
      add :reply_channel_id, references(:inbound_channels, on_delete: :nilify_all)
      add :reviewed_activity_id, :integer, null: false, default: 0
      add :lock_version, :integer, null: false, default: 1
      timestamps(type: :utc_datetime)
    end

    create unique_index(:staff_message_drafts, [:staff_account_id, :thread_id])
    create index(:staff_message_drafts, [:thread_id])
    create index(:staff_message_drafts, [:updated_at])

    for operation <- ["INSERT", "UPDATE"] do
      name = String.downcase(operation)

      execute """
              CREATE TRIGGER staff_draft_scope_#{name}
              BEFORE #{operation} ON staff_message_drafts
              WHEN NOT EXISTS (
                SELECT 1 FROM staff_accounts s JOIN threads t ON t.tenant_id = s.tenant_id
                WHERE s.id = NEW.staff_account_id AND t.id = NEW.thread_id
                  AND (NEW.reply_channel_id IS NULL OR EXISTS (
                    SELECT 1 FROM inbound_channels c
                    WHERE c.id = NEW.reply_channel_id AND c.tenant_id = t.tenant_id
                  ))
              )
              BEGIN
                SELECT RAISE(ABORT, 'draft must remain in its staff tenant');
              END
              """,
              "DROP TRIGGER staff_draft_scope_#{name}"
    end

    for {table, key} <- [{"staff_accounts", "staff_account_id"}, {"threads", "thread_id"}] do
      execute """
              CREATE TRIGGER #{table}_purge_private_drafts
              AFTER UPDATE OF tenant_id ON #{table}
              WHEN OLD.tenant_id != NEW.tenant_id
              BEGIN
                DELETE FROM staff_message_drafts WHERE #{key} = NEW.id;
              END
              """,
              "DROP TRIGGER #{table}_purge_private_drafts"
    end

    execute """
            CREATE TRIGGER inbound_channels_clear_private_draft_sender
            AFTER UPDATE OF tenant_id ON inbound_channels
            WHEN OLD.tenant_id != NEW.tenant_id
            BEGIN
              UPDATE staff_message_drafts SET reply_channel_id = NULL,
                lock_version = lock_version + 1
              WHERE reply_channel_id = NEW.id;
            END
            """,
            "DROP TRIGGER inbound_channels_clear_private_draft_sender"
  end
end
