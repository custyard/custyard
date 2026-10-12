defmodule Custyard.Repo.Migrations.NormalizeOperatorEmails do
  use Ecto.Migration

  import Ecto.Query, only: [from: 2]

  require Logger

  # OperatorAccount.changeset/2 now stores emails trimmed and lowercased, and
  # login looks them up the same way. Accounts saved before that keep their
  # original case and can never log in; normalize them here.
  #
  # Schemaless on purpose: this must keep working whatever the schema module
  # looks like later. Normalization is Unicode String.downcase/1 (the same as
  # OperatorAccount.normalize_email/1), not SQLite's ASCII-only lower().
  #
  # A row whose normalized email equals another row's stored or normalized
  # email belongs to a collision group. Picking a winner would decide who
  # owns the address, so the whole group is skipped with a warning listing
  # the ids; an operator resolves it with `bin/operator list` and `remove`.
  # Rows already normalized are untouched. Nothing here raises on data, so a
  # collision never fails the deploy.
  def up, do: normalize_emails(repo())

  def down, do: :ok

  @doc false
  def normalize_emails(repo) do
    rows = repo.all(from(o in "operator_accounts", select: {o.id, o.email, o.role}))
    {changes, collisions, unreadable} = plan(rows)

    if unreadable != [] do
      Logger.warning(
        "Operator email normalization skipped rows whose email is not UTF-8 text: ids " <>
          Enum.join(unreadable, ", ")
      )
    end

    for ids <- collisions do
      Logger.warning(
        "Operator email normalization skipped a collision group (emails equal ignoring " <>
          "case): ids #{Enum.join(ids, ", ")}. Resolve with `bin/operator list` and " <>
          "`bin/operator remove`."
      )
    end

    for {id, old_email, new_email, role} <- changes do
      repo.update_all(
        from(o in "operator_accounts", where: o.id == ^id and o.email == ^old_email),
        set: [email: new_email]
      )

      Logger.info("Normalized operator email: id #{id}, role #{role}")
    end

    :ok
  end

  @doc false
  # Returns {changes, collision_groups, unreadable_ids} where changes are
  # {id, stored, normalized, role} and each collision group is a sorted id list.
  def plan(rows) do
    {text_rows, other_rows} =
      Enum.split_with(rows, fn {_id, email, _role} -> is_binary(email) and String.valid?(email) end)

    normalized = Map.new(text_rows, fn {id, email, _role} -> {id, normalize(email)} end)

    # Every value, stored or normalized, mapped to the ids holding it.
    holders =
      Enum.reduce(text_rows, %{}, fn {id, email, _role}, acc ->
        acc
        |> Map.update(email, MapSet.new([id]), &MapSet.put(&1, id))
        |> Map.update(normalized[id], MapSet.new([id]), &MapSet.put(&1, id))
      end)

    pending = Enum.reject(text_rows, fn {id, email, _role} -> email == normalized[id] end)

    {changes, collisions} =
      Enum.reduce(pending, {[], MapSet.new()}, fn {id, email, role}, {changes, collisions} ->
        group = holders[normalized[id]]

        if MapSet.size(group) > 1,
          do: {changes, MapSet.put(collisions, group |> MapSet.to_list() |> Enum.sort())},
          else: {[{id, email, normalized[id], role} | changes], collisions}
      end)

    {
      Enum.sort(changes),
      collisions |> MapSet.to_list() |> Enum.sort(),
      other_rows |> Enum.map(&elem(&1, 0)) |> Enum.sort()
    }
  end

  defp normalize(email), do: email |> String.trim() |> String.downcase()
end
