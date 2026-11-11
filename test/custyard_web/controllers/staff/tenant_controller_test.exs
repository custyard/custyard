defmodule CustyardWeb.Admin.TenantAdministrationTest do
  use CustyardWeb.ConnCase
  import Phoenix.LiveViewTest
  alias Custyard.{InstanceAdmins, StaffAccount, Repo, Tenants}

  @moduletag :explicit_tenant_hosts

  test "installation admin provisions tenant with explicit host and first staff", %{conn: conn} do
    {:created, admin} = InstanceAdmins.create_admin("instance@example.com")

    conn =
      conn
      |> init_test_session(%{
        instance_admin_id: admin.id,
        instance_admin_claim: admin.session_claim
      })

    {:ok, view, _} = live(conn, "/admin")

    render_submit(view, "create", %{
      "tenant" => %{
        "name" => "New workspace",
        "slug" => "new",
        "hostname" => "workspace.example.com"
      }
    })

    tenant = Repo.get_by!(Custyard.Tenant, slug: "new")
    assert Tenants.resolve_host("workspace.example.com").id == tenant.id
    {:ok, settings, _} = live(conn, "/admin/tenants/#{tenant.id}/settings")

    render_submit(settings, "staff", %{
      "staff" => %{"email" => "owner@example.com", "role" => "admin"}
    })

    assert Repo.get_by!(StaffAccount, email: "owner@example.com", tenant_id: tenant.id).role ==
             "admin"

    render_click(settings, "status", %{"status" => "suspended"})
    assert Repo.get!(Custyard.Tenant, tenant.id).status == "suspended"
  end

  test "the instance console has no tenant switching session", %{conn: conn} do
    assert %{status: 404} = post(conn, "/app/tenants/1/select")
  end
end
