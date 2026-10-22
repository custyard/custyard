defmodule Custyard.Repo.Migrations.AddArchiveCopyToInboundChannels do
  use Ecto.Migration

  # spec-inbound-channels D4 (archive copy of operator replies, opt-in) and
  # D9 (per-channel attachment cap, default 10 MB per message).
  def change do
    alter table(:inbound_channels) do
      add :archive_copy, :boolean, null: false, default: false
      add :attachment_limit_mb, :integer, null: false, default: 10
    end
  end
end
