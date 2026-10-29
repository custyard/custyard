defmodule CustyardWeb.TenantOutboundPauseTest do
  use CustyardWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Custyard.Factory
  alias Custyard.{Repo, Tenant}

  test "administrator can pause and resume outbound mail in tenant settings", %{conn: conn} do
    tenant = insert_tenant()
    admin = insert_staff_account(tenant_id: tenant.id, role: "admin")
    conn = conn |> init_test_session(%{}) |> put_staff_session(admin)
    {:ok, view, _} = live(conn, "/app/settings/workspace")
    assert has_element?(view, "#outbound-email-control button", "Pause outbound email")

    view |> element("#outbound-email-control button") |> render_click()
    assert Repo.get!(Tenant, tenant.id).outbound_paused
    assert has_element?(view, "#outbound-email-control [role=status]", "Sending is paused")

    view |> element("#outbound-email-control button") |> render_click()
    refute Repo.get!(Tenant, tenant.id).outbound_paused
    assert has_element?(view, "#outbound-email-control button", "Pause outbound email")
  end
end
