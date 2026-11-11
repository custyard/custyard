defmodule Custyard.Repo.Migrations.AddCustomerDefaultContacts do
  use Ecto.Migration

  def up do
    alter table(:organizations) do
      add :default_contact_id, references(:contacts, on_delete: :nilify_all)
    end

    execute """
    UPDATE organizations
    SET default_contact_id = (
      SELECT c.id FROM contacts c
      WHERE c.tenant_id = organizations.tenant_id
        AND c.organization_id = organizations.id
        AND lower(c.email) = organizations.identity_value
    )
    WHERE identity_kind = 'email'
      AND (SELECT count(*) FROM contacts c
           WHERE c.tenant_id = organizations.tenant_id
             AND c.organization_id = organizations.id
             AND lower(c.email) = organizations.identity_value) = 1
    """

    for operation <- ["INSERT", "UPDATE OF default_contact_id, tenant_id"] do
      name = if operation == "INSERT", do: "insert", else: "update"

      execute """
      CREATE TRIGGER organizations_default_contact_scope_#{name}
      BEFORE #{operation} ON organizations
      WHEN NEW.default_contact_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM contacts c
        WHERE c.id = NEW.default_contact_id
          AND c.tenant_id = NEW.tenant_id AND c.organization_id = NEW.id
      )
      BEGIN
        SELECT RAISE(ABORT, 'default contact must belong to this customer and tenant');
      END
      """
    end

    execute """
    CREATE TRIGGER contacts_default_customer_scope
    BEFORE UPDATE OF tenant_id, organization_id ON contacts
    WHEN EXISTS (
      SELECT 1 FROM organizations o
      WHERE o.default_contact_id = OLD.id
        AND (o.tenant_id != NEW.tenant_id OR o.id != NEW.organization_id)
    )
    BEGIN
      SELECT RAISE(ABORT, 'default contact must remain in its customer and tenant');
    END
    """
  end

  def down do
    execute "DROP TRIGGER contacts_default_customer_scope"
    execute "DROP TRIGGER organizations_default_contact_scope_insert"
    execute "DROP TRIGGER organizations_default_contact_scope_update"

    alter table(:organizations) do
      remove :default_contact_id
    end
  end
end
