defmodule Custyard.Repo.Migrations.MakeMessageIdUnique do
  use Ecto.Migration

  @moduledoc """
  Makes message_id unique to enable webhook idempotency.

  Without this, duplicate webhooks (retries on timeout/5xx) create duplicate
  messages. With a unique constraint, we can use ON CONFLICT to safely ignore
  duplicates.

  Uses a partial unique index (WHERE message_id IS NOT NULL) because:
  - Portal/operator messages may not have message_id
  - Webhook messages always have message_id set by adapters
  """

  def change do
    # Drop the old non-unique index
    drop_if_exists index(:messages, [:message_id], name: :messages_message_id_index)

    # Create partial unique index (only enforced when message_id is not null)
    create unique_index(:messages, [:message_id],
             where: "message_id IS NOT NULL",
             name: :messages_message_id_unique_index
           )
  end
end
