defmodule Custyard.Repo.Migrations.AddOperatorSessionClaims do
  use Ecto.Migration

  # Sessions were bound to an operator's creation time, which has second
  # precision: an account removed and replaced within one second (SQLite
  # reuses the highest id) got the same id and claim. Each account now gets a
  # random claim instead. Every existing row is backfilled, so sessions
  # issued with the old creation-time claim stop matching and sign in again.
  def up do
    alter table(:operator_accounts) do
      add :session_claim, :string
    end

    execute "UPDATE operator_accounts SET session_claim = lower(hex(randomblob(16)))"

    create unique_index(:operator_accounts, [:session_claim])
  end

  def down do
    drop index(:operator_accounts, [:session_claim])

    alter table(:operator_accounts) do
      remove :session_claim
    end
  end
end
