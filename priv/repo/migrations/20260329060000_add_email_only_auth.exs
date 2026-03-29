defmodule Custyard.Repo.Migrations.AddEmailOnlyAuth do
  use Ecto.Migration

  def change do
    alter table(:operator_accounts) do
      add :login_token, :string
      add :login_token_expires_at, :utc_datetime
    end

    create index(:operator_accounts, [:login_token], unique: true)
  end
end
