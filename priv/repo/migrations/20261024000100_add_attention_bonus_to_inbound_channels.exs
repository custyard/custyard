defmodule Custyard.Repo.Migrations.AddAttentionBonusToInboundChannels do
  use Ecto.Migration

  # spec-inbound-channels, "Functional impacts by surface": a channel can
  # raise its conversations in the attention queue, so security@ outranks
  # sales@. Points added to the score; 0 leaves every score as it was.
  def change do
    alter table(:inbound_channels) do
      add :attention_bonus, :integer, null: false, default: 0
    end
  end
end
