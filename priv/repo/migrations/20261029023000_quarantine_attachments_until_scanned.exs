defmodule Custyard.Repo.Migrations.QuarantineAttachmentsUntilScanned do
  use Ecto.Migration

  def up do
    alter table(:message_attachments) do
      # Existing files remain quarantined until a real scan succeeds.
      add :scan_status, :string, null: false, default: "pending"
      add :scanned_at, :utc_datetime
      add :scan_token, :string
    end

    create index(:message_attachments, [:tenant_id, :sha256, :scan_status])

    # A stored blob can have several message references. Once malware is found,
    # no duplicate or stale scan result may expose the same bytes as clean.
    for operation <- ["INSERT", "UPDATE OF scan_status, sha256, tenant_id"] do
      suffix = if operation == "INSERT", do: "insert", else: "update"
      terminal = if operation == "INSERT", do: "", else: "OLD.scan_status = 'infected' OR"

      execute """
      CREATE TRIGGER attachment_infected_blob_#{suffix}
      AFTER #{operation} ON message_attachments
      WHEN NEW.sha256 IS NOT NULL AND (
        #{terminal} NEW.scan_status = 'infected' OR EXISTS (
          SELECT 1 FROM message_attachments a
          WHERE a.tenant_id = NEW.tenant_id AND a.sha256 = NEW.sha256
            AND a.scan_status = 'infected'
        )
      )
      BEGIN
        UPDATE message_attachments
        SET scan_status = 'infected', scan_token = NULL
        WHERE tenant_id = NEW.tenant_id AND sha256 = NEW.sha256
          AND (scan_status != 'infected' OR scan_token IS NOT NULL);
      END
      """
    end
  end

  def down do
    execute "DROP TRIGGER IF EXISTS attachment_infected_blob_insert"
    execute "DROP TRIGGER IF EXISTS attachment_infected_blob_update"
    drop index(:message_attachments, [:tenant_id, :sha256, :scan_status])

    alter table(:message_attachments) do
      remove :scan_token
      remove :scanned_at
      remove :scan_status
    end
  end
end
