defmodule Custyard.Repo.Migrations.AddDefaultReplyChannel do
  use Ecto.Migration

  def change do
    alter table(:email_connections) do
      add :default_channel_id, references(:inbound_channels, on_delete: :nilify_all)
    end
  end
end
