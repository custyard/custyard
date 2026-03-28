defmodule Custyard.Repo.Migrations.AddDomainUniquenessToOrganizations do
  use Ecto.Migration

  @doc """
  This migration is intentionally a no-op.

  The unique partial index on organizations.domain was already created by
  migration 20260323050016_add_unique_index_on_organizations_domain.exs.

  This migration existed to ensure domain uniqueness but was created after
  the fix was already applied in migration 016. Keeping as no-op to avoid
  breaking existing deployments that have this migration in schema_migrations.
  """
  def change do
    # Intentionally empty - work done in migration 016
  end
end
