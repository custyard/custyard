defmodule Custyard.Repo.Migrations.AddDeliveryRecoveryFacts do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :delivery_failure_kind, :string
      add :delivery_error_code, :string
      add :delivery_attempted_at, :utc_datetime
      add :delivery_payload_hash, :string
    end
  end
end
