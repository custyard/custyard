defmodule CustyardWeb.Layouts.PortalLayoutTest do
  use CustyardWeb.ConnCase
  import Phoenix.LiveViewTest
  import Custyard.Factory
  alias Custyard.Tenants

  test "workspace branding supplies portal name, logo, metadata and theme", %{conn: conn} do
    customer = insert_organization(name: "Customer company")
    tenant = Tenants.get_tenant!(customer.tenant_id)

    {:ok, _} =
      Tenants.update_tenant(tenant, %{
        name: "Onboarding workspace",
        logo_url: "/uploads/logos/brand.png",
        primary_color: "#123456"
      })

    {:ok, _, html} = live(conn, "/portal/#{portal_token(customer)}")
    assert html =~ "Onboarding workspace"
    assert html =~ "content=\"Customer portal for Onboarding workspace\""
    assert html =~ "/uploads/logos/brand.png"
    assert html =~ "background-color: #123456"
    refute html =~ "og-image.png"
    refute html =~ "Customer company logo"
  end

  test "workspace defaults have no customer branding fallback", %{conn: conn} do
    customer = insert_organization(name: "Customer company")
    {:ok, _, html} = live(conn, "/portal/#{portal_token(customer)}")
    assert html =~ "Tenant"
    assert html =~ "background-color: #4f46e5"
    refute html =~ "data-testid=\"portal-nav-logo\""
  end
end
