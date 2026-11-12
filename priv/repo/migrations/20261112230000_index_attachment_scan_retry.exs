defmodule Custyard.Repo.Migrations.IndexAttachmentScanRetry do
  use Ecto.Migration

  # Custyard.Attachments.retry_failed_scans/1 runs every minute and selects
  # failed scans stored in the last day. Without this index that query reads
  # the whole table, which a remote database bills per row.
  def change do
    create index(:message_attachments, [:scan_status, :inserted_at])
  end
end
