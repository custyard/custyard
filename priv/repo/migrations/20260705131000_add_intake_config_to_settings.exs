defmodule Custyard.Repo.Migrations.AddIntakeConfigToSettings do
  use Ecto.Migration

  def change do
    alter table(:settings) do
      # Public intake configuration as JSON
      # Keys:
      #   "unlinked_tier_score" - tier-equivalent score for conversations without
      #     an organization (integer 0..100, default 10 = standard tier)
      #   "slug_claim_ttl_hours" - lifetime of an unconfirmed slug claim
      #     (integer 1..720, default 72)
      add :intake_config, :map, default: %{}
    end
  end
end
