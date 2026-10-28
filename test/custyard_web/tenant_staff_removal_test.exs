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
    {:ok, admin_view, _} = live(admin_conn, "/app/settings/workspace")
    {:ok, agent_view, _} = live(agent_conn, "/app")
    assert has_element?(admin_view, "[data-testid=staff-#{c.agent.id}] button[data-confirm]")
    refute has_element?(admin_view, "[data-testid=staff-#{c.admin.id}] button")

    admin_view |> element("[data-testid=staff-#{c.agent.id}] button") |> render_click()
    refute Repo.get(OperatorAccount, c.agent.id)
    refute has_element?(admin_view, "[data-testid=staff-#{c.agent.id}]")
    audit = Repo.get_by!(AuditEvent, event_type: :operator_removed)
    assert audit.payload["operator_id"] == c.agent.id
    assert audit.source == "tenant:#{c.tenant.id}:staff:#{c.admin.id}"
    render_click(agent_view, "toggle_score", %{"id" => "1"})
    assert_redirect(agent_view, "/app/login")
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

  test "self removal is refused; a second administrator can remove staff", c do
    assert {:error, :self_removal} = Tenants.remove_staff(c.admin, c.tenant.id, c.admin.id)
    second = insert_operator_account(role: "admin", tenant_id: c.tenant.id)
    assert {:ok, _} = Tenants.remove_staff(second, c.tenant.id, c.admin.id)
    refute Repo.get(OperatorAccount, c.admin.id)
  end

  test "staff removal preserves message history and clears tenant-constrained actor references",
       c do
    customer = insert_organization(tenant_id: c.tenant.id)
    conversation = insert_conversation(organization_id: customer.id)
    message = insert_message(conversation_id: conversation.id, body: "Preserved history")

    message =
      message
      |> Ecto.Changeset.change(
        deleted_by_operator_id: c.agent.id,
        forwarded_by_operator_id: c.agent.id
      )
      |> Repo.update!()

    assert {:ok, _} = Tenants.remove_staff(c.admin, c.tenant.id, c.agent.id)
    kept = Repo.reload!(message)
    assert kept.body == "Preserved history"
    assert kept.tenant_id == c.tenant.id
    assert is_nil(kept.deleted_by_operator_id)
    assert is_nil(kept.forwarded_by_operator_id)
    event = Repo.get_by!(AuditEvent, event_type: :operator_removed, tenant_id: c.tenant.id)
    assert event.payload["deleted_message_ids"] == [message.id]
    assert event.payload["forwarded_message_ids"] == [message.id]
  end
end
