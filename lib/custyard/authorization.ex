defmodule Custyard.Authorization do
  @moduledoc """
  Pure authorization module for RBAC enforcement.

  Operates entirely on in-memory `%OperatorAccount{}` structs -- zero DB calls.
  All permission checks are based on the operator's role and organization_id.

  ## Role Hierarchy

  - `super_admin` (3): Full access to all resources across all organizations
  - `admin` (2): Manage own organization's resources
  - `agent` (1): View/reply within own organization only
  """

  alias Custyard.OperatorAccount

  @role_rank %{"super_admin" => 3, "admin" => 2, "agent" => 1}

  @doc """
  Returns true if the operator has at least the given role level.
  """
  def has_minimum_role?(%OperatorAccount{role: role}, required_role) do
    Map.get(@role_rank, role, 0) >= Map.get(@role_rank, required_role, 0)
  end

  def has_minimum_role?(_, _), do: false

  @doc """
  Only super_admin can create organizations.
  """
  def can_create_organization?(%OperatorAccount{role: "super_admin"}), do: true
  def can_create_organization?(_), do: false

  @doc """
  super_admin can manage any org; admin can manage their own org.
  """
  def can_manage_organization?(%OperatorAccount{role: "super_admin"}, _org_id), do: true

  def can_manage_organization?(%OperatorAccount{role: "admin", organization_id: org_id}, org_id)
      when is_integer(org_id),
      do: true

  def can_manage_organization?(_, _), do: false

  @doc """
  Only super_admin can modify global settings.
  """
  def can_modify_settings?(%OperatorAccount{role: "super_admin"}), do: true
  def can_modify_settings?(_), do: false

  @doc """
  super_admin can manage any project; admin can manage projects in their own org.
  """
  def can_manage_project?(%OperatorAccount{role: "super_admin"}, _org_id), do: true

  def can_manage_project?(%OperatorAccount{role: "admin", organization_id: op_org_id}, org_id)
      when op_org_id == org_id,
      do: true

  def can_manage_project?(_, _), do: false

  @doc """
  admin+ can set conversation state (active, waiting, resolved).
  """
  def can_set_conversation_state?(%OperatorAccount{} = op),
    do: has_minimum_role?(op, "admin")

  def can_set_conversation_state?(_), do: false

  @doc """
  super_admin can access any conversation; others must be in the same org.
  """
  def can_access_conversation?(%OperatorAccount{role: "super_admin"}, _conversation), do: true

  def can_access_conversation?(%OperatorAccount{organization_id: org_id}, conversation),
    do: conversation.organization_id == org_id

  def can_access_conversation?(_, _), do: false
end
