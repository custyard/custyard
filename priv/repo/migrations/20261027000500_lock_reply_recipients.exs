defmodule Custyard.Repo.Migrations.LockReplyRecipients do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :delivery_recipients_locked, :boolean, default: false, null: false
    end
  end
end
