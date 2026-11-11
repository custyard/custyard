defmodule Custyard.Authorization do
  @moduledoc "Tenant staff authorization. Instance administrators have no customer access."
  alias Custyard.{StaffAccount, Scope}
  @role_rank %{"admin" => 2, "agent" => 1}

  def has_minimum_role?(%StaffAccount{role: role}, required)
      when is_map_key(@role_rank, role) and is_map_key(@role_rank, required),
      do: @role_rank[role] >= @role_rank[required]

  def has_minimum_role?(_, _), do: false

  def can_create_organization?(%StaffAccount{role: "admin", tenant_id: id})
      when is_integer(id) do
    true
  end

  def can_create_organization?(_), do: false

  def can_manage_organization?(%StaffAccount{role: "admin"} = staff, id),
    do: StaffAccount.can_access_organization?(staff, id)

  def can_manage_organization?(_, _), do: false

  def can_modify_settings?(%StaffAccount{role: "admin", tenant_id: id}) when is_integer(id),
    do: true

  def can_modify_settings?(_), do: false

  def can_manage_project?(%StaffAccount{role: "admin", tenant_id: id}, nil)
      when is_integer(id) do
    true
  end

  def can_manage_project?(staff, id), do: can_manage_organization?(staff, id)
  def can_set_thread_state?(staff), do: has_minimum_role?(staff, "admin")

  def can_access_thread?(%StaffAccount{tenant_id: id}, %{tenant_id: id})
      when is_integer(id) do
    true
  end

  def can_access_thread?(%Scope{} = scope, resource), do: Scope.tenant?(scope, resource)
  def can_access_thread?(_, _), do: false
end
