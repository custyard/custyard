defmodule Custyard.Repo.Migrations.AddNeglectNotificationTracking do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      # Tracks the last neglect level that triggered a notification
      # Prevents duplicate alerts when recalculating
      add :last_neglect_notification, :string
    end
  end
end
