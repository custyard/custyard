defmodule Custyard.Repo.Migrations.CreateOperatorAccounts do
  use Ecto.Migration

  def change do
    create table(:operator_accounts) do
      add :email, :string, null: false
      add :password_hash, :string, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:operator_accounts, [:email])
  end
end
