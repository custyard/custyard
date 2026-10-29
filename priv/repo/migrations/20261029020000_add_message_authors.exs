defmodule Custyard.Repo.Migrations.AddMessageAuthors do
  use Ecto.Migration

  def up do
    alter table(:messages) do
      add :author_staff_id, references(:staff_accounts, on_delete: :nilify_all)
    end

    create index(:messages, [:author_staff_id])

    for operation <- ["INSERT", "UPDATE OF author_staff_id, tenant_id"] do
      name = if operation == "INSERT", do: "insert", else: "update"

      execute """
      CREATE TRIGGER messages_author_scope_#{name}
      BEFORE #{operation} ON messages
      WHEN NEW.author_staff_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM staff_accounts s
        WHERE s.id = NEW.author_staff_id AND s.tenant_id = NEW.tenant_id
      )
      BEGIN
        SELECT RAISE(ABORT, 'message author must belong to its tenant');
      END
      """
    end

    execute """
    CREATE TRIGGER staff_authored_message_scope
    BEFORE UPDATE OF tenant_id ON staff_accounts
    WHEN EXISTS (
      SELECT 1 FROM messages m
      WHERE m.author_staff_id = OLD.id AND m.tenant_id != NEW.tenant_id
    )
    BEGIN
      SELECT RAISE(ABORT, 'message author must remain in its tenant');
    END
    """
  end

  def down do
    execute "DROP TRIGGER staff_authored_message_scope"
    execute "DROP TRIGGER messages_author_scope_insert"
    execute "DROP TRIGGER messages_author_scope_update"

    drop index(:messages, [:author_staff_id])

    alter table(:messages) do
      remove :author_staff_id
    end
  end
end
