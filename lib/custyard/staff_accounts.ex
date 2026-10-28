defmodule Custyard.StaffAccounts do
  @moduledoc "Tenant staff accounts. All identity lookups require an explicit tenant."
  import Ecto.Query
  alias Custyard.{StaffAccount, Repo}
  def valid_id?(id), do: is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807

  def get_by_email(tenant_id, email) when is_integer(tenant_id),
    do:
      Repo.get_by(StaffAccount,
        tenant_id: tenant_id,
        email: StaffAccount.normalize_email(email)
      )

  def get_by_email(_, _), do: nil

  def list_staff(tenant_id),
    do: Repo.all(from a in StaffAccount, where: a.tenant_id == ^tenant_id, order_by: a.id)

  def create_staff(email, opts) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)

    case get_by_email(tenant_id, email) do
      %StaffAccount{} = staff -> {:exists, staff}
      nil -> insert_staff(email, opts)
    end
  end

  def insert_staff(email, opts) do
    changeset =
      StaffAccount.changeset(%StaffAccount{}, %{
        email: email,
        tenant_id: Keyword.fetch!(opts, :tenant_id),
        role: Keyword.get(opts, :role, "admin")
      })

    case Repo.insert(changeset) do
      {:ok, staff} -> {:created, staff}
      {:error, changeset} -> {:error, changeset}
    end
  end

  def remove_staff(tenant_id, email) do
    case get_by_email(tenant_id, email) do
      nil -> {:error, :not_found}
      staff -> Repo.delete(staff)
    end
  end
end
