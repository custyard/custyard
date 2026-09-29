defmodule Custyard.OperatorAccess do
  @moduledoc """
  Transactional operator lookup for resource mutations.

  Call inside a Repo transaction, before locking the resource row. Holding the
  operator row prevents a concurrent role or organization reassignment from
  committing between authorization and the protected write.
  """

  import Ecto.Query

  alias Custyard.{OperatorAccount, Repo}

  def lock_current(%OperatorAccount{id: id}) when is_integer(id) do
    query =
      from(o in OperatorAccount,
        where: o.id == ^id,
        update: [set: [updated_at: o.updated_at]]
      )

    case Repo.update_all(query, []) do
      {1, _} -> Repo.get!(OperatorAccount, id)
      {0, _} -> nil
    end
  end

  def lock_current(_), do: nil
end
