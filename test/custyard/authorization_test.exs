defmodule Custyard.AuthorizationTest do
  use Custyard.DataCase
  alias Custyard.{Authorization, Factory, InstanceAdmin, StaffAccount}

  test "staff permissions respect tenant ownership and admin role" do
    own = Factory.insert_organization()
    foreign = Factory.insert_organization(tenant_id: Factory.insert_tenant().id)
    admin = Factory.insert_staff_account(tenant_id: own.tenant_id, role: "admin")
    agent = Factory.insert_staff_account(tenant_id: own.tenant_id, role: "agent")
    assert Authorization.can_create_organization?(admin)
    refute Authorization.can_create_organization?(agent)
    assert Authorization.can_manage_organization?(admin, own.id)
    refute Authorization.can_manage_organization?(admin, foreign.id)
    refute Authorization.can_manage_organization?(agent, own.id)
    assert Authorization.can_manage_project?(admin, nil)
    assert Authorization.can_modify_settings?(admin)
    refute Authorization.can_modify_settings?(agent)
    assert Authorization.can_access_thread?(agent, %{tenant_id: own.tenant_id})
    refute Authorization.can_access_thread?(agent, %{tenant_id: foreign.tenant_id})
    refute StaffAccount.can_access_organization?(agent, foreign.id)

    for actor <- [%InstanceAdmin{}, nil, %{}] do
      refute Authorization.can_access_thread?(actor, %{tenant_id: own.tenant_id})
      refute Authorization.can_create_organization?(actor)
      refute Authorization.can_modify_settings?(actor)
    end
  end

  test "the staff role hierarchy has no installation role" do
    assert Authorization.has_minimum_role?(%StaffAccount{role: "admin"}, "agent")
    assert Authorization.has_minimum_role?(%StaffAccount{role: "admin"}, "admin")
    refute Authorization.has_minimum_role?(%StaffAccount{role: "agent"}, "admin")
    refute Authorization.has_minimum_role?(%StaffAccount{role: "admin"}, "super_admin")
  end
end
