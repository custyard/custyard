defmodule Custyard.Repo.Migrations.LowercaseOperatorAccountEmails do
  use Ecto.Migration

  import Ecto.Query

  # The login form downcases the submitted address and looks the account up
  # by exact match, and OperatorAccount.changeset/2 now stores emails
  # lowercased. Accounts saved before that keep their original case and can
  # never receive a login link; lowercase them here.
  #
  # Only ASCII letters are folded, in Elixir rather than with SQL lower():
  # on Postgres lower() follows the database locale (under tr_TR, "I"
  # becomes "ı"), which would irreversibly store a form the app never
  # produces. Non-ASCII uppercase stays as it is, which is also what SQLite's
  # lower() did; a later full Unicode pass still has the original text.
  #
  # email is NOT NULL, so a row that would collide on the unique index is
  # skipped and keeps its original case. An all-lowercase row was the only
  # one that could log in, so it keeps the address; among rows none of which
  # could, the oldest is lowercased. Skipped rows were unreachable before and
  # stay that way.
  def up do
    rows = repo().all(from o in "operator_accounts", select: {o.id, o.email}, order_by: o.id)

    owners = for {id, email} <- rows, fold(email) == email, into: %{}, do: {email, id}

    Enum.reduce(rows, owners, fn {id, email}, owners ->
      folded = fold(email)

      if folded == email or is_map_key(owners, folded) do
        owners
      else
        repo().update_all(from(o in "operator_accounts", where: o.id == ^id),
          set: [email: folded]
        )

        Map.put(owners, folded, id)
      end
    end)

    :ok
  end

  def down, do: :ok

  # Byte-wise A-Z to a-z, so it also leaves invalid UTF-8 untouched.
  defp fold(email), do: String.downcase(email, :ascii)
end
