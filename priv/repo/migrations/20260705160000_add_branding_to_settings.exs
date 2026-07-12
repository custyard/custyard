defmodule Custyard.Repo.Migrations.AddBrandingToSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      # Instance branding for the public intake surface as JSON.
      # Whitelisted keys:
      #   "name" - display name (max 100 chars; consumers fall back to "Custyard")
      #   "logo_url" - same-origin /uploads/ path (traversal-checked)
      #   "primary_color" - hex color like #1a2b3c
      add :branding, :map, default: %{}
    end
  end
end
