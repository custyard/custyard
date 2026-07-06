defmodule Custyard.Repo.Migrations.CreateSlugs do
  use Ecto.Migration

  @moduledoc """
  Creates the slug registry — the single table that owns the entire
  organization-slug namespace (claimed, confirmed, and provisioned slugs;
  see docs/design/design-decisions-public-intake.md §Slug Registry).

  The table is created via raw `execute` because SQLite cannot ADD a
  CONSTRAINT after creation and both CHECKs must live in the database:

  - the status enum CHECK, and
  - the pairing invariant `(status = 'provisioned') = (organization_id IS
    NOT NULL)` — a provisioned slug always belongs to an organization and
    only provisioned slugs do. SQLite boolean equality: both sides evaluate
    to 0/1 (status is NOT NULL, so neither side is ever NULL).

  `available` = no row: expiry and operator release DELETE the row, so the
  unique index on `slug` is the whole namespace guarantee (a tombstone
  would block re-claim).
  """

  def up do
    execute """
    CREATE TABLE slugs (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      slug TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'claimed'
        CHECK (status IN ('claimed','confirmed','provisioned')),
      email TEXT NULL,
      conversation_id INTEGER NULL REFERENCES conversations(id) ON DELETE SET NULL,
      organization_id INTEGER NULL REFERENCES organizations(id) ON DELETE CASCADE,
      confirmation_token_hash TEXT NULL,
      expires_at TEXT NULL,
      confirmed_at TEXT NULL,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      CHECK ((status = 'provisioned') = (organization_id IS NOT NULL))
    )
    """

    # THE namespace guarantee: no two live rows (any status) share a slug.
    create unique_index(:slugs, [:slug])

    # Partial uniques (WHERE-NOT-NULL, codebase convention): one slug per
    # organization, one live claim per conversation, one row per token hash.
    create unique_index(:slugs, [:organization_id], where: "organization_id IS NOT NULL")
    create unique_index(:slugs, [:conversation_id], where: "conversation_id IS NOT NULL")

    create unique_index(:slugs, [:confirmation_token_hash],
             where: "confirmation_token_hash IS NOT NULL"
           )

    # Per-email live-claim bound counting.
    create index(:slugs, [:email])
    # Expiry sweep and lazy-expiry lookups.
    create index(:slugs, [:status, :expires_at])
  end

  def down do
    execute "DROP TABLE slugs"
  end
end
