defmodule Custyard.Repo.Migrations.AddFidelityFieldsToMessagesAndConversations do
  use Ecto.Migration

  # spec-inbound-channels Phase 2 (email fidelity): the sanitised HTML body
  # stored alongside the text body (D9), the operator who manually forwarded a
  # customer thread into Custyard (D6 "operator manual forward"), and the
  # detected language of a conversation (enrichment).
  def change do
    alter table(:messages) do
      # Allowlist-sanitised at ingest; never the raw provider HTML.
      add :html_body, :text
      add :forwarded_by_operator_id, references(:operator_accounts, on_delete: :nilify_all)
      # The operator-owned address a manual forward or an outside reply came
      # from, kept when no operator account matches it (a shared mailbox).
      add :forwarded_by_email, :string
    end

    create index(:messages, [:forwarded_by_operator_id])

    alter table(:conversations) do
      # ISO 639-1 code from the first customer message, nil when undetected.
      add :language, :string, size: 8
    end
  end
end
