defmodule Custyard.Repo.Migrations.CreateConversations do
  use Ecto.Migration

  def change do
    create table(:conversations) do
      add :organization_id, references(:organizations, on_delete: :delete_all), null: false
      add :contact_id, references(:contacts, on_delete: :nilify_all)
      add :subject, :string, null: false
      add :state, :string, default: "new", null: false
      add :urgency, :string, default: "normal", null: false
      add :cached_score, :integer, default: 0, null: false
      add :last_operator_action_at, :utc_datetime
      add :last_customer_action_at, :utc_datetime
      add :snoozed_until, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:conversations, [:organization_id])
    create index(:conversations, [:state])
    create index(:conversations, [:cached_score])
  end
end
