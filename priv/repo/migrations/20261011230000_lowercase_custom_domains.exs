defmodule Custyard.Repo.Migrations.LowercaseCustomDomains do
  use Ecto.Migration

  # Hostnames are case-insensitive and Organization.changeset/2 now stores
  # custom domains lowercased, so the unique index on custom_domain enforces
  # case-insensitive uniqueness and the portal lookup can be an exact match.
  # Rows saved before that keep their original case; lowercase them here.
  #
  # Two rows differing only in case would collide on the unique index. Only
  # an all-lowercase value ever resolved (browsers send the host lowercased
  # and the lookup was exact), so that row keeps the domain; among rows none
  # of which resolved, the oldest does. The others lose a custom domain that
  # never routed to them.
  def up do
    execute("""
    UPDATE organizations
    SET custom_domain = NULL
    WHERE custom_domain IS NOT NULL
      AND custom_domain <> lower(custom_domain)
      AND EXISTS (
        SELECT 1 FROM organizations AS other
        WHERE other.id <> organizations.id
          AND lower(other.custom_domain) = lower(organizations.custom_domain)
          AND (other.custom_domain = lower(other.custom_domain) OR other.id < organizations.id)
      )
    """)

    execute("""
    UPDATE organizations
    SET custom_domain = lower(custom_domain)
    WHERE custom_domain IS NOT NULL AND custom_domain <> lower(custom_domain)
    """)
  end

  def down, do: :ok
end
