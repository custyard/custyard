defmodule Custyard.Repo.Migrations.CreateEmailConnections do
  use Ecto.Migration

  def change do
    create table(:email_connections) do
      add :tenant_id, references(:tenants, on_delete: :delete_all), null: false
      add :project_id, :string
      add :project_token_ciphertext, :text
      add :team_token_ciphertext, :text
      add :status_webhook_id, :string
      add :status_secret_ciphertext, :text
      add :status_callback_token, :string, null: false
      add :project_checked_at, :utc_datetime
      add :project_check_status, :string, default: "unchecked", null: false
      add :sending_checked_at, :utc_datetime
      add :sending_check_status, :string, default: "unchecked", null: false
      add :last_signed_inbound_at, :utc_datetime
      add :last_reply_accepted_at, :utc_datetime
      add :last_reply_delivered_at, :utc_datetime
      add :last_status_event_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:email_connections, [:tenant_id])
    create unique_index(:email_connections, [:status_callback_token])

    alter table(:inbound_routes) do
      add :lettermint_webhook_id, :string
      add :webhook_secret_ciphertext, :text
      add :webhook_verified_at, :utc_datetime
    end
  end
end
