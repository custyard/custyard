defmodule Custyard.OperatorAccounts do
  @moduledoc "Tenant staff accounts. All identity lookups require an explicit tenant."
  import Ecto.Query
  alias Custyard.{OperatorAccount, Repo}
  def valid_id?(id), do: is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807

  def get_by_email(tenant_id, email) when is_integer(tenant_id),
    do:
      Repo.get_by(OperatorAccount,
        tenant_id: tenant_id,
        email: OperatorAccount.normalize_email(email)
      )

  def get_by_email(_, _), do: nil

  def list_operators(tenant_id),
    do: Repo.all(from a in OperatorAccount, where: a.tenant_id == ^tenant_id, order_by: a.id)

  def create_operator(email, opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)

    case get_by_email(tenant_id, email) do
      %OperatorAccount{} = staff -> {:exists, staff}
      nil -> insert_operator(email, opts)
    end
  end

  def insert_operator(email, opts) do
    changeset =
      OperatorAccount.changeset(%OperatorAccount{}, %{
        email: email,
        tenant_id: Keyword.fetch!(opts, :tenant_id),
        role: Keyword.get(opts, :role, "admin")
      })

    case Repo.insert(changeset) do
      {:ok, staff} -> {:created, staff}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def remove_operator(tenant_id, email) do
    case get_by_email(tenant_id, email) do
      nil -> {:error, :not_found}
      staff -> Repo.delete(staff)
    end
  end
end
