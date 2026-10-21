defmodule Custyard.Repo.Migrations.AddChannelFieldsToConversationsAndMessages do
  use Ecto.Migration

  # spec-inbound-channels D5/D6: the matched channel on the conversation, and
  # the per-message email facts the thread view and triage need. Nothing here
  # holds raw message URLs, attachment content, spam symbols or remote IPs.
  def change do
    alter table(:conversations) do
      add :inbound_channel_id, references(:inbound_channels, on_delete: :nilify_all)
      # Set when the first message was spam-flagged or unauthenticated from an
      # unknown sender (D6 "suspect"). Cleared by an operator.
      add :suspect, :boolean, null: false, default: false
    end

    create index(:conversations, [:inbound_channel_id])

    alter table(:messages) do
      add :inbound_channel_id, references(:inbound_channels, on_delete: :nilify_all)
      # SQLite stores arrays as JSON text (see projects.tags).
      add :to_addresses, :text, default: "[]"
      add :cc_addresses, :text, default: "[]"
      add :reply_to, :string
      # Compact map: %{"dkim", "dkim_domain", "spf", "dmarc"}
      add :authentication, :map
      add :spam_score, :float
      # customer | auto_response | suspect; nil for operator and portal rows
      add :triage_class, :string
    end
  end
end
