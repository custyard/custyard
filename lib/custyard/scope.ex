defmodule Custyard.Scope do
  @moduledoc "An authenticated tenant and staff boundary supplied to resource contexts."
  alias Custyard.{OperatorAccount, Tenant}
  @type t :: %__MODULE__{tenant_id: integer(), staff_id: integer() | nil, role: String.t()}
  @enforce_keys [:tenant_id, :role]
  defstruct [:tenant_id, :staff_id, :role, :session_claim]

  def for_staff(
        %OperatorAccount{tenant_id: id, id: staff_id, role: role, session_claim: claim},
        %Tenant{
          id: id,
          status: "active"
        }
      )
      when is_integer(id) and role in ~w(admin agent),
      do: %__MODULE__{tenant_id: id, staff_id: staff_id, role: role, session_claim: claim}

  def for_staff(_, _), do: nil

  def tenant?(%__MODULE__{tenant_id: id}, %{tenant_id: id}), do: true
  def tenant?(_, _), do: false
  def admin?(%__MODULE__{role: "admin"}), do: true
  def admin?(_), do: false

  @doc "Resolve a scope only while its staff membership and session remain current."
  def current_staff(%__MODULE__{staff_id: id} = scope) when is_integer(id) do
    staff = Custyard.Repo.get(OperatorAccount, id)
    tenant = Custyard.Repo.get(Tenant, scope.tenant_id)

    if staff && staff.tenant_id == scope.tenant_id && staff.role == scope.role &&
         OperatorAccount.session_claim_matches?(staff, scope.session_claim) &&
         match?(%Tenant{status: "active"}, tenant),
       do: staff
  end

  def current_staff(_), do: nil
end
