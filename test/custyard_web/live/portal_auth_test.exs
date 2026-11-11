defmodule CustyardWeb.Live.PortalAuthTest do
  use CustyardWeb.ConnCase
  import Phoenix.LiveViewTest
  import Custyard.Factory
  alias Custyard.{PortalCredentials, Tenants}

  test "portal token grants only its customer on the registered tenant host", %{conn: conn} do
    customer = insert_organization()
    other = insert_organization()
    insert_thread(organization_id: customer.id, subject: "Customer private thread")
    insert_thread(organization_id: other.id, subject: "Other private thread")
    conn = conn |> init_test_session(%{portal_org_id: other.id, portal_custom_domain: true})
    {:ok, _, html} = live(conn, "/portal/#{portal_token(customer)}")
    assert html =~ "Customer private thread"
    refute html =~ "Other private thread"
    foreign = insert_tenant()
    {:ok, _} = Tenants.add_host(foreign.id, "foreign.example.com")

    assert get(%{build_conn() | host: "foreign.example.com"}, "/portal/#{portal_token(customer)}").status ==
             404
  end

  test "revoked and invalid credentials do not use old session organization flags", %{conn: conn} do
    customer = insert_organization()

    {:ok, credential, token} =
      PortalCredentials.issue(portal_scope(customer), customer.id)

    {:ok, _} =
      PortalCredentials.revoke(portal_scope(customer), credential)

    conn = conn |> init_test_session(%{portal_org_id: customer.id, portal_custom_domain: true})
    assert get(conn, "/portal/#{token}").status == 404
    assert get(conn, "/portal/invalid").status == 404
  end

  test "tenant custom hosts retain token URLs and workspace branding", %{conn: conn} do
    customer = insert_organization()
    tenant = Tenants.get_tenant!(customer.tenant_id)
    {:ok, _} = Tenants.update_tenant(tenant, %{name: "Workspace brand", primary_color: "#123456"})
    {:ok, _} = Tenants.add_host(tenant.id, "support.example.com")

    {:ok, _, html} =
      live(%{conn | host: "support.example.com"}, "/portal/#{portal_token(customer)}")

    assert html =~ "Workspace brand"
    assert html =~ "#123456"
    assert html =~ "/portal/#{portal_token(customer)}/new"
    refute html =~ "href=\"/new\""
  end
end
