defmodule Custyard.Repo.Migrations.CreateMessageRecipientStatuses do
  use Ecto.Migration

  # spec-conversation-loop, "Delivery Tracking": the provider reports delivery
  # per recipient, so each outbound message keeps the latest status of every
  # address it was sent to. `role` records which list the address was on when
  # the reply went out (to, cc, other); the message's own indicator follows
  # its `to` recipient only, so a bounced CC address never marks a reply the
  # customer received as bounced. `status_at` is the provider's event time,
  # so a late event cannot undo a newer one. Rows go with their message.
  def change do
    create table(:message_recipient_statuses) do
      add :message_id, references(:messages, on_delete: :delete_all), null: false
      # lower-cased, trimmed address as the provider named it
      add :address, :string, null: false
      # to | cc | other
      add :role, :string, null: false
      # sent | delivered | failed | bounced | suppressed
      add :status, :string, null: false
      add :status_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:message_recipient_statuses, [:message_id, :address])
  end
end
