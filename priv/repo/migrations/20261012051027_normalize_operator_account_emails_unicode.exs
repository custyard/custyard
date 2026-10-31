defmodule Custyard.Repo.Migrations.NormalizeOperatorAccountEmailsUnicode do
  use Ecto.Migration

  import Ecto.Query

  require Custyard.Log, as: Log

  # 20261012022249 folded only ASCII letters, and neither trimmed nor
  # NFC-normalized emails. OperatorAccount.normalize_email/1 stores
  # emails trimmed, lowercased with full Unicode case mapping, and in NFC;
  # this brings existing rows to the same form so the login lookup finds
  # them. It runs in Elixir so the result does not depend on the database.
  #
  # The normalization is copied here rather than calling the app function, so
  # a later change to that function cannot change what this migration did.
  #
  # Same collision rule as 20261012022249: a row already in normalized form
  # keeps the address, otherwise the lowest id does. A row that is skipped
  # (collision, or not valid UTF-8) keeps its email and is logged by id: it
  # still cannot log in, and someone has to resolve it by hand.
  def up do
    rows = repo().all(from o in "operator_accounts", select: {o.id, o.email}, order_by: o.id)

    owners = for {id, email} <- rows, normalize(email) == email, into: %{}, do: {email, id}

    Enum.reduce(rows, owners, fn {id, email}, owners ->
      case normalize(email) do
        ^email ->
          owners

        :invalid ->
          Log.warning(:operator_email_normalization_skipped, operator_id: id, reason: :invalid_utf8)
          owners

        normalized when is_map_key(owners, normalized) ->
          Log.warning(:operator_email_normalization_skipped,
            operator_id: id, conflicting_operator_id: owners[normalized], reason: :normalization_collision
          )

          owners

        normalized ->
          repo().update_all(from(o in "operator_accounts", where: o.id == ^id),
            set: [email: normalized]
          )

          Map.put(owners, normalized, id)
      end
    end)

    :ok
  end

  def down, do: :ok

  defp normalize(email) do
    if String.valid?(email),
      do: email |> String.trim() |> String.downcase() |> :unicode.characters_to_nfc_binary(),
      else: :invalid
  end
end
