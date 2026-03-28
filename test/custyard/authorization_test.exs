defmodule Custyard.AuthorizationTest do
  use ExUnit.Case, async: true

  alias Custyard.{Authorization, OperatorAccount}

  defp super_admin do
    %OperatorAccount{role: "super_admin", organization_id: nil}
  end

  defp admin(org_id) do
    %OperatorAccount{role: "admin", organization_id: org_id}
  end

  defp agent(org_id) do
    %OperatorAccount{role: "agent", organization_id: org_id}
  end

  describe "has_minimum_role?/2" do
    test "super_admin meets all role requirements" do
      op = super_admin()
      assert Authorization.has_minimum_role?(op, "agent")
      assert Authorization.has_minimum_role?(op, "admin")
      assert Authorization.has_minimum_role?(op, "super_admin")
    end

    test "admin meets admin and agent requirements" do
      op = admin(1)
      assert Authorization.has_minimum_role?(op, "agent")
      assert Authorization.has_minimum_role?(op, "admin")
      refute Authorization.has_minimum_role?(op, "super_admin")
    end

    test "agent meets only agent requirement" do
      op = agent(1)
      assert Authorization.has_minimum_role?(op, "agent")
      refute Authorization.has_minimum_role?(op, "admin")
      refute Authorization.has_minimum_role?(op, "super_admin")
    end

    test "returns false for nil" do
      refute Authorization.has_minimum_role?(nil, "agent")
    end
  end

  describe "can_create_organization?/1" do
    test "super_admin can create organizations" do
      assert Authorization.can_create_organization?(super_admin())
    end

    test "admin cannot create organizations" do
      refute Authorization.can_create_organization?(admin(1))
    end

    test "agent cannot create organizations" do
      refute Authorization.can_create_organization?(agent(1))
    end
  end

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

  describe "can_modify_settings?/1" do
    test "super_admin can modify settings" do
      assert Authorization.can_modify_settings?(super_admin())
    end

    test "admin cannot modify settings" do
      refute Authorization.can_modify_settings?(admin(1))
    end

    test "agent cannot modify settings" do
      refute Authorization.can_modify_settings?(agent(1))
    end
  end

  describe "can_manage_project?/2" do
    test "super_admin can manage any project" do
      assert Authorization.can_manage_project?(super_admin(), 1)
      assert Authorization.can_manage_project?(super_admin(), nil)
    end

    test "admin can manage projects in own org" do
      assert Authorization.can_manage_project?(admin(1), 1)
    end

    test "admin cannot manage projects in other org" do
      refute Authorization.can_manage_project?(admin(1), 2)
    end

    test "agent cannot manage any project" do
      refute Authorization.can_manage_project?(agent(1), 1)
    end
  end

  describe "can_set_conversation_state?/1" do
    test "super_admin can set conversation state" do
      assert Authorization.can_set_conversation_state?(super_admin())
    end

    test "admin can set conversation state" do
      assert Authorization.can_set_conversation_state?(admin(1))
    end

    test "agent cannot set conversation state" do
      refute Authorization.can_set_conversation_state?(agent(1))
    end
  end

  describe "can_access_conversation?/2" do
    test "super_admin can access any conversation" do
      conversation = %{organization_id: 1}
      assert Authorization.can_access_conversation?(super_admin(), conversation)
    end

    test "admin can access conversations in own org" do
      conversation = %{organization_id: 1}
      assert Authorization.can_access_conversation?(admin(1), conversation)
    end

    test "admin cannot access conversations in other org" do
      conversation = %{organization_id: 2}
      refute Authorization.can_access_conversation?(admin(1), conversation)
    end

    test "agent can access conversations in own org" do
      conversation = %{organization_id: 1}
      assert Authorization.can_access_conversation?(agent(1), conversation)
    end

    test "agent cannot access conversations in other org" do
      conversation = %{organization_id: 2}
      refute Authorization.can_access_conversation?(agent(1), conversation)
    end
  end
end
