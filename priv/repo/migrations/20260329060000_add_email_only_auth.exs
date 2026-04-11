defmodule Custyard.Repo.Migrations.AddEmailOnlyAuth do
  use Ecto.Migration

  @moduledoc """
  Adds email-only authentication support (magic link login).

  SQLite doesn't support ALTER COLUMN, so we must recreate the table
  to make password_hash nullable. New columns (login_token, login_token_expires_at)
  are added via the recreated table definition.
  """

  def up do
    # 1. Create new table with nullable password_hash and login token fields
    execute """
    CREATE TABLE operator_accounts_new (
      id INTEGER PRIMARY KEY,
      email TEXT NOT NULL,
      password_hash TEXT,
      login_token TEXT,
      login_token_expires_at TEXT,
      role TEXT DEFAULT 'super_admin' NOT NULL,
      organization_id INTEGER REFERENCES organizations(id) ON DELETE SET NULL,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """

    # 2. Copy existing data
    execute """
    INSERT INTO operator_accounts_new (id, email, password_hash, role, organization_id, inserted_at, updated_at)
    SELECT id, email, password_hash, role, organization_id, inserted_at, updated_at
    FROM operator_accounts
    """

    # 3. Drop old table
    execute "DROP TABLE operator_accounts"

    # 4. Rename new table
    execute "ALTER TABLE operator_accounts_new RENAME TO operator_accounts"

    # 5. Recreate indexes
    create unique_index(:operator_accounts, [:email])
    create index(:operator_accounts, [:organization_id])
    create index(:operator_accounts, [:role])
    create unique_index(:operator_accounts, [:login_token])
  end

  def down do
    # Reverse: remove login token fields and make password_hash NOT NULL again
    # This will fail if any rows have null password_hash
    execute """
    CREATE TABLE operator_accounts_new (
      id INTEGER PRIMARY KEY,
      email TEXT NOT NULL,
      password_hash TEXT NOT NULL,
      role TEXT DEFAULT 'super_admin' NOT NULL,
      organization_id INTEGER REFERENCES organizations(id) ON DELETE SET NULL,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """

    execute """
    INSERT INTO operator_accounts_new (id, email, password_hash, role, organization_id, inserted_at, updated_at)
    SELECT id, email, password_hash, role, organization_id, inserted_at, updated_at
    FROM operator_accounts
    WHERE password_hash IS NOT NULL
    """

    execute "DROP TABLE operator_accounts"
    execute "ALTER TABLE operator_accounts_new RENAME TO operator_accounts"

    create unique_index(:operator_accounts, [:email])
    create index(:operator_accounts, [:organization_id])
    create index(:operator_accounts, [:role])
  end
end
