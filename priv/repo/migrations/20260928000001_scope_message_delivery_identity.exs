defmodule Custyard.Repo.Migrations.ScopeMessageDeliveryIdentity do
  use Ecto.Migration

  def up do
    alter table(:messages) do
      add :dedup_scope, :string
    end

    # Existing deliveries have no recorded inbound route. Preserve their
    # organization/provider scope, then use route IDs for new deliveries.
    execute("""
    UPDATE messages
    SET dedup_scope = 'org:' || COALESCE((
      SELECT CAST(conversations.organization_id AS TEXT)
      FROM conversations WHERE conversations.id = messages.conversation_id
    ), 'unlinked') || ':source:' || COALESCE(origin, source, 'email') || ':route:0'
    WHERE message_id IS NOT NULL
    """)

    drop_if_exists index(:messages, [:message_id], name: :messages_message_id_unique_index)

    create unique_index(:messages, [:dedup_scope, :message_id],
             where: "message_id IS NOT NULL AND dedup_scope IS NOT NULL",
             name: :messages_dedup_scope_message_id_index
           )

    create index(:messages, [:message_id])
    create index(:messages, [:dedup_scope, :in_reply_to])
  end

  def down do
    drop_if_exists index(:messages, [:dedup_scope, :in_reply_to])
    drop_if_exists index(:messages, [:message_id])

    drop_if_exists index(:messages, [:dedup_scope, :message_id],
                     name: :messages_dedup_scope_message_id_index
                   )

    create unique_index(:messages, [:message_id],
             where: "message_id IS NOT NULL",
             name: :messages_message_id_unique_index
           )

    alter table(:messages) do
      remove :dedup_scope
    end
  end
end
