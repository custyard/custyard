defmodule Custyard.Repo.Migrations.RestrictTenantStaffDeletion do
  use Ecto.Migration

  def up do
    # The original deployed baseline combined NOT NULL and SET NULL. Enforce
    # the intended restriction before that foreign key runs, without rebuilding
    # the staff table referenced by message authors and private drafts.
    execute """
    CREATE TRIGGER tenants_restrict_staff_deletion
    BEFORE DELETE ON tenants
    WHEN EXISTS (SELECT 1 FROM staff_accounts WHERE tenant_id = OLD.id)
    BEGIN
      SELECT RAISE(ABORT, 'cannot delete a tenant with staff accounts');
    END
    """
  end

  def down do
    execute "DROP TRIGGER tenants_restrict_staff_deletion"
  end
end
