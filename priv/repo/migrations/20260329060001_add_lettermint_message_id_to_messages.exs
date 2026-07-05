defmodule Custyard.Repo.Migrations.AddLettermintMessageIdToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      add :lettermint_message_id, :string
    end
  end
end
