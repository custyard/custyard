defmodule Custyard.Repo.Migrations.AddImapSettingsToInboundChannels do
  use Ecto.Migration

  # spec-inbound-channels D8: per-channel IMAP replaces the single global
  # poller. The password is stored only as Custyard.Credentials ciphertext.
  # The poller reads the folder read-only and remembers the last UID it
  # handled under the folder's UIDVALIDITY, so it never changes flags in the
  # operator's mailbox. Rejected logins and retries of one message are
  # counted separately from other failures: they decide when polling stops
  # and when a message is passed over, while the overall count drives
  # backoff.
  def change do
    alter table(:inbound_channels) do
      add :imap_host, :string, size: 255
      add :imap_port, :integer
      add :imap_username, :string, size: 320
      add :imap_password_ciphertext, :text
      add :imap_folder, :string, size: 255
      add :imap_uid_validity, :bigint
      add :imap_last_uid, :bigint
      add :imap_last_polled_at, :utc_datetime
      add :imap_last_error, :string, size: 64
      add :imap_consecutive_failures, :integer, null: false, default: 0
      add :imap_auth_failures, :integer, null: false, default: 0
      add :imap_message_attempts, :integer, null: false, default: 0
      add :imap_auth_failed_at, :utc_datetime
    end
  end
end
