defmodule Custyard.Repo.Migrations.AllowNullOrganizationIdOnConversations do
  use Ecto.Migration

  @moduledoc """
  Allows null organization_id on conversations for disambiguation-state conversations.

  SQLite doesn't support ALTER COLUMN, so we must recreate the table.
  This migration:
  1. Creates a new table with nullable organization_id
  2. Copies all data from the old table
  3. Drops the old table
  4. Renames the new table
  5. Recreates indexes
  """

  def up do
    # 1. Create new conversations table with nullable organization_id
    execute """
    CREATE TABLE conversations_new (
      id INTEGER PRIMARY KEY,
      organization_id INTEGER REFERENCES organizations(id) ON DELETE CASCADE,
      contact_id INTEGER REFERENCES contacts(id) ON DELETE SET NULL,
      project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
      subject TEXT NOT NULL,
      state TEXT DEFAULT 'new' NOT NULL,
      urgency TEXT DEFAULT 'normal' NOT NULL,
      source TEXT DEFAULT 'email',
      cached_score INTEGER DEFAULT 0 NOT NULL,
      last_operator_action_at TEXT,
      last_customer_action_at TEXT,
      snoozed_until TEXT,
      last_neglect_notification TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """

    # 2. Copy all existing data
    execute """
    INSERT INTO conversations_new
    SELECT id, organization_id, contact_id, project_id, subject, state, urgency, source,
           cached_score, last_operator_action_at, last_customer_action_at, snoozed_until,
           last_neglect_notification, inserted_at, updated_at
    FROM conversations
    """

    # 3. Drop old table
    execute "DROP TABLE conversations"

    # 4. Rename new table
    execute "ALTER TABLE conversations_new RENAME TO conversations"

    # 5. Recreate indexes
    create index(:conversations, [:organization_id])
    create index(:conversations, [:state])
    create index(:conversations, [:cached_score])
    create index(:conversations, [:project_id])
    create index(:conversations, [:source])
  end

  def down do
    # Reverse: Make organization_id NOT NULL again
    # This will fail if any rows have null organization_id
    execute """
    CREATE TABLE conversations_new (
      id INTEGER PRIMARY KEY,
      organization_id INTEGER NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
      contact_id INTEGER REFERENCES contacts(id) ON DELETE SET NULL,
      project_id INTEGER REFERENCES projects(id) ON DELETE SET NULL,
      subject TEXT NOT NULL,
      state TEXT DEFAULT 'new' NOT NULL,
      urgency TEXT DEFAULT 'normal' NOT NULL,
      source TEXT DEFAULT 'email',
      cached_score INTEGER DEFAULT 0 NOT NULL,
      last_operator_action_at TEXT,
      last_customer_action_at TEXT,
      snoozed_until TEXT,
      last_neglect_notification TEXT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """

    execute """
    INSERT INTO conversations_new
    SELECT id, organization_id, contact_id, project_id, subject, state, urgency, source,
           cached_score, last_operator_action_at, last_customer_action_at, snoozed_until,
           last_neglect_notification, inserted_at, updated_at
    FROM conversations
    WHERE organization_id IS NOT NULL
    """

    execute "DROP TABLE conversations"
    execute "ALTER TABLE conversations_new RENAME TO conversations"

    create index(:conversations, [:organization_id])
    create index(:conversations, [:state])
    create index(:conversations, [:cached_score])
    create index(:conversations, [:project_id])
    create index(:conversations, [:source])
  end
end
