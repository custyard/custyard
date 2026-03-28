defmodule Custyard.Repo.Migrations.UpdateContactUniqueness do
  @moduledoc """
  NOTE: This migration is redundant with 20260323050017.

  Both migrations change contacts email index to a composite (email, organization_id).
  The earlier migration (050017) already handles this. This migration was developed
  in parallel and uses _if_exists/_if_not_exists to be safely idempotent.

  Kept for existing deployments where schema_migrations has already recorded it.
  """
  use Ecto.Migration

  def change do
    # These operations are no-ops if 050017 already ran (which it did)
    drop_if_exists index(:contacts, [:email], name: :contacts_email_index)
    drop_if_exists unique_index(:contacts, [:email], name: :contacts_email_index)
    create_if_not_exists unique_index(:contacts, [:email, :organization_id])
  end
end
