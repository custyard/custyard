defmodule CustyardWeb.HomeLiveTest do
  use CustyardWeb.ConnCase
  import Phoenix.LiveViewTest
  import Custyard.Factory
  alias Custyard.Tenants

  @moduletag :explicit_tenant_hosts

  test "installation homepage introduces Custyard and separates workspace and administrator entry",
       %{
         conn: conn
       } do
    {:ok, _, html} = live(conn, "/")
    assert html =~ "Customer onboarding, with support in one place"
    assert html =~ "Custyard is an open-source platform"
    assert html =~ "Find your workspace"
    assert html =~ "href=\"/admin/login\""
    refute html =~ "href=\"/app/login\""

    assert html |> Floki.parse_document!() |> Floki.find("title") |> Floki.text() |> String.trim() ==
             "Custyard"
  end

  test "tenant homepage uses workspace branding and links to tenant staff sign in", %{conn: conn} do
    tenant = insert_tenant(name: "Acme onboarding")
    {:ok, _} = Tenants.add_host(tenant.id, "acme.example.com")
    {:ok, _, html} = live(%{conn | host: "acme.example.com"}, "/")
    assert html =~ "Welcome to Acme onboarding"
    assert html =~ "Staff sign in"
    assert html =~ "href=\"/app/login\""
    assert html =~ "private thread or portal link"
    refute html =~ "Find your workspace"
    refute html =~ "Acme onboarding · Acme onboarding"
  end

  test "workspace lookup resolves normalized slug to the registered canonical host", %{conn: conn} do
    tenant = insert_tenant(slug: "acme")
    {:ok, _} = Tenants.add_host(tenant.id, "support.acme.example")
    {:ok, _} = Tenants.add_host(tenant.id, "other.acme.example")
    {:ok, view, _} = live(conn, "/")

    view |> form("#workspace-finder", workspace: %{slug: " ACME "}) |> render_submit()
    assert_redirect(view, login_url("support.acme.example"))
  end

  test "lookup rejects unknown, suspended, unregistered and URL-shaped inputs", %{conn: conn} do
    suspended = insert_tenant(slug: "suspended", status: "suspended")
    {:ok, _} = Tenants.add_host(suspended.id, "suspended.example.com")
    insert_tenant(slug: "unregistered")

    for slug <- [
          "missing",
          "suspended",
          "unregistered",
          "https://attacker.example",
          "//attacker.example"
        ] do
      {:ok, view, _} = live(conn, "/")
      html = view |> form("#workspace-finder", workspace: %{slug: slug}) |> render_submit()
      assert html =~ "Workspace unavailable. Check the workspace name and try again."
      assert has_element?(view, "#workspace-finder")
    end
  end

  test "connected homepage uses transport host rather than navigation URL or session tenant", %{
    conn: conn
  } do
    tenant = insert_tenant(name: "Private workspace")
    {:ok, _} = Tenants.add_host(tenant.id, "private.example.com")

    conn =
      %{conn | host: "private.example.com"}
      |> init_test_session(%{host_tenant_id: tenant.id})
      |> put_private(:live_view_connect_info, %{uri: %URI{host: Tenants.app_host()}})

    {:ok, view, _html} = live(conn, "/")
    assert render(view) =~ "Find your workspace"
    refute render(view) =~ "Private workspace"
  end

  test "installation root branding ignores authenticated or legacy tenant assigns" do
    tenant = insert_tenant(name: "Private workspace")

    branding =
      CustyardWeb.Layouts.root_branding(%{current_tenant: tenant, site_name: tenant.name})

    assert branding.name == "Custyard"
    refute branding.tenant?
    assert CustyardWeb.Layouts.root_branding(%{host_tenant: tenant}).name == tenant.name
  end

  defp login_url(host) do
    CustyardWeb.Endpoint.url()
    |> URI.parse()
    |> Map.merge(%{host: host, path: "/app/login"})
    |> URI.to_string()
  end
end
