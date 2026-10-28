defmodule Custyard.Repo.Migrations.AddChannelSendingDomain do
  use Ecto.Migration

  def change do
    alter table(:inbound_channels) do
      add :sending_domain, :string
    end
  end
end
