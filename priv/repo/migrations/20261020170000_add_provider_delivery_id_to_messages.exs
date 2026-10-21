defmodule Custyard.Repo.Migrations.AddProviderDeliveryIdToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      # Lettermint's top-level webhook delivery `id`, reused on every retry of
      # one delivery. Nullable: nil for outbound messages and for inbound
      # messages from sources that do not carry a delivery id.
      add :provider_delivery_id, :string
    end

    create unique_index(:messages, [:provider_delivery_id],
             where: "provider_delivery_id IS NOT NULL",
             name: :messages_provider_delivery_id_index
           )

    # Delivery-status webhooks correlate by the provider message id.
    create index(:messages, [:lettermint_message_id],
             where: "lettermint_message_id IS NOT NULL"
           )
  end
end
