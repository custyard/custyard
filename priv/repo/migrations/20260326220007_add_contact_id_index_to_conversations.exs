defmodule Custyard.Repo.Migrations.AddContactIdIndexToConversations do
  use Ecto.Migration

  def change do
    # contact_id is used in Conversations.list_for_organization/2 filter
    # Without this index, queries filtering by contact_id do full table scans
    create index(:conversations, [:contact_id])
  end
end
