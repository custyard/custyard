defmodule CustyardWeb.TenantStaffRemovalTest do
  use CustyardWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Custyard.Factory
  alias Custyard.{AuditEvent, OperatorAccount, Repo, Tenants}

  setup do
    {:ok, tenant} =
      Tenants.create_tenant(%{name: "Staff", slug: "staff-#{System.unique_integer([:positive])}"})

    admin = insert_operator_account(role: "admin", tenant_id: tenant.id)
    agent = insert_operator_account(role: "agent", tenant_id: tenant.id)
    %{tenant: tenant, admin: admin, agent: agent}
  end

  test "removing tenant staff is confirmed, audited and revokes open sessions", c do
    admin_conn = c.conn |> init_test_session(%{}) |> put_operator_session(c.admin)
    agent_conn = build_conn() |> init_test_session(%{}) |> put_operator_session(c.agent)
    {:ok, admin_view, _} = live(admin_conn, "/operator/tenant")
    {:ok, agent_view, _} = live(agent_conn, "/operator")
    assert has_element?(admin_view, "[data-testid=staff-#{c.agent.id}] button[data-confirm]")
    refute has_element?(admin_view, "[data-testid=staff-#{c.admin.id}] button")

    admin_view |> element("[data-testid=staff-#{c.agent.id}] button") |> render_click()
    refute Repo.get(OperatorAccount, c.agent.id)
    refute has_element?(admin_view, "[data-testid=staff-#{c.agent.id}]")
    audit = Repo.get_by!(AuditEvent, event_type: :operator_removed)
    assert audit.payload["operator_id"] == c.agent.id
    assert audit.source == "operator"
    assert audit.payload["actor_operator_id"] == c.admin.id
    assert audit.payload["tenant_id"] == c.tenant.id
    render_click(agent_view, "toggle_score", %{"id" => "1"})
    assert_redirect(agent_view, "/operator/login")
  end

  test "scope and refreshed authority prevent foreign and stale removals", c do
    {:ok, other} =
      Tenants.create_tenant(%{name: "Other", slug: "other-#{System.unique_integer([:positive])}"})

    foreign = insert_operator_account(role: "agent", tenant_id: other.id)
    assert {:error, :not_found} = Tenants.remove_staff(c.admin, c.tenant.id, foreign.id)
    assert {:error, :unauthorized} = Tenants.remove_staff(c.admin, other.id, foreign.id)
    assert {:error, :unauthorized} = Tenants.remove_staff(c.agent, c.tenant.id, c.admin.id)
    c.admin |> OperatorAccount.role_changeset(%{role: "agent"}) |> Repo.update!()
    assert {:error, :unauthorized} = Tenants.remove_staff(c.admin, c.tenant.id, c.agent.id)
    assert Repo.get(OperatorAccount, foreign.id)
    assert Repo.get(OperatorAccount, c.agent.id)
  end

  test "self removal and removing the last tenant administrator are refused", c do
    assert {:error, :self_removal} = Tenants.remove_staff(c.admin, c.tenant.id, c.admin.id)
    super_admin = insert_operator_account()
    assert {:error, :last_admin} = Tenants.remove_staff(super_admin, c.tenant.id, c.admin.id)
    insert_operator_account(role: "admin", tenant_id: c.tenant.id)
    assert {:ok, _} = Tenants.remove_staff(super_admin, c.tenant.id, c.admin.id)
  end

  test "legacy staff keep one customer until an instance administrator grants tenant access", c do
    org = insert_organization(tenant_id: c.tenant.id)
    other = insert_organization(tenant_id: c.tenant.id)
    legacy = insert_operator_account(role: "admin", organization_id: org.id, tenant_id: nil)
    super_admin = insert_operator_account()
    refute OperatorAccount.can_access_organization?(legacy, other.id)
    assert {:error, :unauthorized} = Tenants.grant_tenant_access(c.admin, c.tenant.id, legacy.id)

    super_conn =
      c.conn
      |> init_test_session(%{selected_tenant_id: c.tenant.id})
      |> put_operator_session(super_admin)

    legacy_conn = build_conn() |> init_test_session(%{}) |> put_operator_session(legacy)
    {:ok, old_view, _} = live(legacy_conn, "/operator")
    {:ok, view, html} = live(super_conn, "/operator/tenant")
    assert html =~ "every customer"
    assert has_element?(view, "[data-testid=legacy-staff-#{legacy.id}] button[data-confirm]")
    view |> element("[data-testid=legacy-staff-#{legacy.id}] button") |> render_click()
    converted = Repo.reload!(legacy)
    assert converted.tenant_id == c.tenant.id
    assert is_nil(converted.organization_id)
    assert converted.role == legacy.role
    refute converted.session_claim == legacy.session_claim
    assert OperatorAccount.can_access_organization?(converted, other.id)

    audit = Repo.get_by!(AuditEvent, event_type: :operator_tenant_access_granted)
    assert audit.source == "operator"
    assert audit.payload["operator_id"] == legacy.id
    assert audit.payload["actor_operator_id"] == super_admin.id
    assert audit.payload["tenant_id"] == c.tenant.id

    render_click(old_view, "toggle_score", %{"id" => "1"})
    assert_redirect(old_view, "/operator/login")
  end

  test "tenant access grants reject foreign staff and stale instance administrators", c do
    org = insert_organization()
    legacy = insert_operator_account(role: "agent", organization_id: org.id)
    super_admin = insert_operator_account()
    assert {:error, :not_found} = Tenants.grant_tenant_access(super_admin, c.tenant.id, legacy.id)

    super_admin
    |> Ecto.Changeset.change(session_claim: OperatorAccount.generate_session_claim())
    |> Repo.update!()

    assert {:error, :unauthorized} =
             Tenants.grant_tenant_access(super_admin, org.tenant_id, legacy.id)

    assert Repo.reload!(legacy).tenant_id == nil
  end
end
