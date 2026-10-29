defmodule Custyard.Repo.Migrations.AddCustomerPublicIds do
  use Ecto.Migration

  def up do
    alter table(:organizations) do
      add :public_id, :string
    end

    flush()

    for [id] <- repo().query!("SELECT id FROM organizations").rows do
      repo().query!("UPDATE organizations SET public_id = ? WHERE id = ?", [
        Ecto.UUID.generate(),
        id
      ])
    end

    create unique_index(:organizations, [:public_id])

    # SQLite cannot add NOT NULL to an existing column. Enforce it without
    # rebuilding the customer table and its many foreign-key relationships.
    for operation <- ["INSERT", "UPDATE OF public_id"] do
      name = if operation == "INSERT", do: "insert", else: "update"

      execute """
      CREATE TRIGGER organizations_public_id_required_#{name}
      BEFORE #{operation} ON organizations
      WHEN NEW.public_id IS NULL OR length(NEW.public_id) != 36
      BEGIN
        SELECT RAISE(ABORT, 'customer public_id must be a UUID');
      END
      """
    end
  end

  def down do
    execute "DROP TRIGGER organizations_public_id_required_insert"
    execute "DROP TRIGGER organizations_public_id_required_update"
    drop index(:organizations, [:public_id])

    alter table(:organizations) do
      remove :public_id
    end
  end
end
