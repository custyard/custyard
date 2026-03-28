defmodule Custyard.Repo.Migrations.AddOriginToMessages do
  use Ecto.Migration

  def change do
    alter table(:messages) do
      # Tracks original adapter source (lettermint, zendesk, etc.) for audit/reporting
      # Separate from :source which indicates message type (email, portal, operator)
      add :origin, :string
    end
  end
end
