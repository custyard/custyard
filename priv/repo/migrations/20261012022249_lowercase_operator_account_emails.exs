defmodule Custyard.Repo.Migrations.LowercaseOperatorAccountEmails do
  use Ecto.Migration

  # The login form downcases the submitted address and looks the account up
  # by exact match, and OperatorAccount.changeset/2 now stores emails
  # lowercased. Accounts saved before that keep their original case and can
  # never receive a login link; lowercase them here.
  #
  # email is NOT NULL, so a row that would collide on the unique index is
  # skipped and keeps its original case. An all-lowercase row was the only
  # one that could log in, so it keeps the address; among rows none of which
  # could, the oldest is lowercased. Skipped rows were unreachable before and
  # stay that way.
  def up do
    execute("""
    UPDATE operator_accounts
    SET email = lower(email)
    WHERE email <> lower(email)
      AND NOT EXISTS (
        SELECT 1 FROM operator_accounts AS other
        WHERE other.id <> operator_accounts.id
          AND lower(other.email) = lower(operator_accounts.email)
          AND (other.email = lower(other.email) OR other.id < operator_accounts.id)
      )
    """)
  end

  def down, do: :ok
end
