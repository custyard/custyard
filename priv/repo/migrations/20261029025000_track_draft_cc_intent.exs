defmodule Custyard.Repo.Migrations.TrackDraftCcIntent do
  use Ecto.Migration

  def up do
    alter table(:staff_message_drafts) do
      add :reply_cc_edited, :boolean, null: false, default: false
    end

    # Existing drafts restored every saved CC list as an override, including
    # an empty list. Preserve that intent rather than guessing from body text.
    execute "UPDATE staff_message_drafts SET reply_cc_edited = TRUE"
  end

  def down do
    alter table(:staff_message_drafts) do
      remove :reply_cc_edited
    end
  end
end
