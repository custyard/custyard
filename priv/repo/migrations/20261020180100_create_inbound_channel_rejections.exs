defmodule Custyard.Repo.Migrations.CreateInboundChannelRejections do
  use Ecto.Migration

  # Deliveries that reached a route but did not become a customer message:
  # no matching channel, paused channel, auto-responses without a thread,
  # provider notifications. Kept 14 days (spec-inbound-channels, Privacy and
  # compliance: Retention) so an operator can answer "did my customer's mail
  # get lost?". Sender and subject only; never the body.
  def change do
    create table(:inbound_channel_rejections) do
      add :inbound_route_id, references(:inbound_routes, on_delete: :delete_all), null: false
      add :inbound_channel_id, references(:inbound_channels, on_delete: :delete_all)
      add :organization_id, references(:organizations, on_delete: :delete_all), null: false

      add :sender_email, :string
      add :recipient, :string
      add :subject, :string
      add :classification, :string, null: false
      add :provider_delivery_id, :string

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:inbound_channel_rejections, [:inbound_route_id, :inserted_at])
    create index(:inbound_channel_rejections, [:inbound_channel_id])
    create index(:inbound_channel_rejections, [:inserted_at])
  end
end
