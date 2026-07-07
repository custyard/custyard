defmodule Custyard.AuthorizationTest do
  use ExUnit.Case, async: true

  alias Custyard.Authorization
  alias Custyard.OperatorAccount

  # Test fixtures — plain structs, no DB needed.
  # These mirror the schema shape so Authorization can pattern-match on fields.

  defp super_admin do
    %OperatorAccount{id: 1, role: "super_admin", organization_id: nil}
  end

  defp admin(org_id \\ 1) do
    %OperatorAccount{id: 2, role: "admin", organization_id: org_id}
  end

  defp agent(org_id \\ 1) do
    %OperatorAccount{id: 3, role: "agent", organization_id: org_id}
  end

  # -------------------------------------------------------------------
  # has_minimum_role?/2
  # -------------------------------------------------------------------
  describe "has_minimum_role?/2" do
    test "super_admin meets all role requirements" do
      assert Authorization.has_minimum_role?(super_admin(), "agent")
      assert Authorization.has_minimum_role?(super_admin(), "admin")
      assert Authorization.has_minimum_role?(super_admin(), "super_admin")
    end

    test "admin meets admin and agent requirements" do
      assert Authorization.has_minimum_role?(admin(), "agent")
      assert Authorization.has_minimum_role?(admin(), "admin")
      refute Authorization.has_minimum_role?(admin(), "super_admin")
    end

    test "agent only meets agent requirement" do
      assert Authorization.has_minimum_role?(agent(), "agent")
      refute Authorization.has_minimum_role?(agent(), "admin")
      refute Authorization.has_minimum_role?(agent(), "super_admin")
    end

    test "returns false for unknown required role" do
      refute Authorization.has_minimum_role?(super_admin(), "owner")
    end

    test "returns false for nil operator" do
      refute Authorization.has_minimum_role?(nil, "agent")
    end
  end

  # -------------------------------------------------------------------
  # can_create_organization?/1
  # -------------------------------------------------------------------
  describe "can_create_organization?/1" do
    test "super_admin can create organizations" do
      assert Authorization.can_create_organization?(super_admin())
    end

    test "admin cannot create organizations" do
      refute Authorization.can_create_organization?(admin())
    end

    test "agent cannot create organizations" do
      refute Authorization.can_create_organization?(agent())
    end
  end

  # -------------------------------------------------------------------
  # can_manage_organization?/2
  # -------------------------------------------------------------------
  describe "can_manage_organization?/2" do
    test "super_admin can manage any organization" do
      assert Authorization.can_manage_organization?(super_admin(), 1)
      assert Authorization.can_manage_organization?(super_admin(), 999)
    end

    test "admin can manage own organization" do
      assert Authorization.can_manage_organization?(admin(1), 1)
    end

    test "admin cannot manage other organization" do
      refute Authorization.can_manage_organization?(admin(1), 2)
    end

    test "agent cannot manage any organization" do
      refute Authorization.can_manage_organization?(agent(1), 1)
    end
  end

  # -------------------------------------------------------------------
  # can_modify_settings?/1
  # -------------------------------------------------------------------
  describe "can_modify_settings?/1" do
    test "super_admin can modify settings" do
      assert Authorization.can_modify_settings?(super_admin())
    end

    test "admin cannot modify settings" do
      refute Authorization.can_modify_settings?(admin())
    end

    test "agent cannot modify settings" do
      refute Authorization.can_modify_settings?(agent())
    end
  end

  # -------------------------------------------------------------------
  # can_manage_project?/2
  # -------------------------------------------------------------------
  describe "can_manage_project?/2" do
    test "super_admin can manage any project regardless of org" do
      assert Authorization.can_manage_project?(super_admin(), 1)
      assert Authorization.can_manage_project?(super_admin(), 999)
    end

    test "admin can manage project in own org" do
      assert Authorization.can_manage_project?(admin(1), 1)
    end

    test "admin cannot manage project in other org" do
      refute Authorization.can_manage_project?(admin(1), 2)
    end

    test "agent cannot manage projects even in own org" do
      refute Authorization.can_manage_project?(agent(1), 1)
    end
  end

  # -------------------------------------------------------------------
  # can_set_conversation_state?/1
  # -------------------------------------------------------------------
  describe "can_set_conversation_state?/1" do
    test "super_admin can set conversation state" do
      assert Authorization.can_set_conversation_state?(super_admin())
    end

    test "admin can set conversation state" do
      assert Authorization.can_set_conversation_state?(admin())
    end

    test "agent cannot set conversation state" do
      refute Authorization.can_set_conversation_state?(agent())
    end
  end

  # -------------------------------------------------------------------
  # can_access_conversation?/2
  # -------------------------------------------------------------------
  describe "can_access_conversation?/2" do
    test "super_admin can access conversation in any org" do
      conv = %{organization_id: 999}
      assert Authorization.can_access_conversation?(super_admin(), conv)
    end

    test "admin can access conversation in own org" do
      conv = %{organization_id: 1}
      assert Authorization.can_access_conversation?(admin(1), conv)
    end

    test "admin cannot access conversation in other org" do
      conv = %{organization_id: 2}
      refute Authorization.can_access_conversation?(admin(1), conv)
    end

    test "agent can access conversation in own org" do
      conv = %{organization_id: 1}
      assert Authorization.can_access_conversation?(agent(1), conv)
    end

    test "agent cannot access conversation in other org" do
      conv = %{organization_id: 2}
      refute Authorization.can_access_conversation?(agent(1), conv)
    end

    test "conversation with nil organization_id is accessible to all operator roles" do
      conv = %{organization_id: nil}
      assert Authorization.can_access_conversation?(super_admin(), conv)
      assert Authorization.can_access_conversation?(admin(1), conv)
      assert Authorization.can_access_conversation?(agent(1), conv)
    end

    test "non-operator still cannot access a nil-org conversation" do
      refute Authorization.can_access_conversation?(nil, %{organization_id: nil})
    end
  end

  # -------------------------------------------------------------------
  # role_rank/1 (if exposed — verify ordering invariants)
  # -------------------------------------------------------------------
  describe "role hierarchy" do
    test "super_admin outranks admin" do
      assert Authorization.has_minimum_role?(super_admin(), "admin")
      refute Authorization.has_minimum_role?(admin(), "super_admin")
    end

    test "admin outranks agent" do
      assert Authorization.has_minimum_role?(admin(), "agent")
      refute Authorization.has_minimum_role?(agent(), "admin")
    end

    test "hierarchy is transitive — super_admin outranks agent" do
      assert Authorization.has_minimum_role?(super_admin(), "agent")
      refute Authorization.has_minimum_role?(agent(), "super_admin")
    end
  end
end
