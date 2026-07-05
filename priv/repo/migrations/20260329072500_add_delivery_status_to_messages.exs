defmodule Custyard.Repo.Migrations.AddDeliveryStatusToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      # Nullable: nil for inbound messages, set for outbound (:pending, :sent, :failed, :bounced)
      add :delivery_status, :string
    end
  end
end
