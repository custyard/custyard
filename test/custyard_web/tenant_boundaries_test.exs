defmodule CustyardWeb.TenantBoundariesTest do
  use CustyardWeb.ConnCase
  @moduletag :explicit_tenant_hosts
  import Phoenix.LiveViewTest
  alias Custyard.{Auth.Account, InstanceAdmins, StaffAccount, Repo, Tenants}

  setup do
    {:ok, tenant} = Tenants.create_tenant(%{name: "Workspace", slug: "workspace"})
    {:ok, _} = Tenants.add_host(tenant.id, "workspace.example.com")

    {:ok, staff} =
      %StaffAccount{}
      |> StaffAccount.changeset(%{
        email: "staff@onetimesecret.com",
        role: "admin",
        tenant_id: tenant.id
      })
      |> Repo.insert()

    {:created, admin} = InstanceAdmins.create_admin("staff@custyard.com")
    %{tenant: tenant, staff: staff, admin: admin}
  end

  test "staff email setup is accessible before support email exists", %{conn: conn, staff: staff} do
    conn =
      %{conn | host: "workspace.example.com"}
      |> init_test_session(%{})
      |> put_staff_session(staff)

    assert {:ok, _, html} = live(conn, "/app/settings/email")
    assert html =~ "Connect your support address"
  end

  test "instance identity does not authenticate tenant staff", %{conn: conn, admin: admin} do
    conn =
      %{conn | host: "workspace.example.com"}
      |> init_test_session(%{
        instance_admin_id: admin.id,
        instance_admin_claim: admin.session_claim
      })

    assert redirected_to(get(conn, "/app")) == "/app/login"
  end

  test "staff identity does not authenticate installation console", %{conn: conn, staff: staff} do
    conn =
      %{conn | host: "workspace.example.com"}
      |> init_test_session(%{})
      |> put_staff_session(staff)

    assert %{status: 404} = get(conn, "/admin")
  end

  test "revoked instance admin cannot load tenant settings through a connected patch", %{
    conn: conn,
    admin: admin,
    tenant: tenant
  } do
    conn =
      %{conn | host: Tenants.app_host()}
      |> init_test_session(%{
        instance_admin_id: admin.id,
        instance_admin_claim: admin.session_claim
      })

    {:ok, view, _html} = live(conn, "/admin")
    admin |> Ecto.Changeset.change(session_claim: Ecto.UUID.generate()) |> Repo.update!()

    render_patch(view, "/admin/tenants/#{tenant.id}/settings")
    assert_redirect(view, "/admin/login")
  end

  test "unknown and suspended hosts refuse tenant access", %{
    conn: conn,
    tenant: tenant,
    admin: admin
  } do
    assert %{status: 404} = get(%{conn | host: "unknown.example.com"}, "/app/login")
    assert {:ok, _} = Tenants.set_status(admin, tenant.id, "suspended")
    assert %{status: 403} = get(%{conn | host: "workspace.example.com"}, "/app/login")
    assert %{status: 200} = get(%{conn | host: Tenants.app_host()}, "/admin/login")
  end

  test "realms have distinct host-only cookies, paths and salts" do
    staff = CustyardWeb.Endpoint.session_options(:staff)
    admin = CustyardWeb.Endpoint.session_options(:admin)
    assert staff[:key] != admin[:key]
    assert staff[:signing_salt] != admin[:signing_salt]
    assert staff[:encryption_salt] != admin[:encryption_salt]
    assert staff[:path] == "/app"
    assert admin[:path] == "/admin"
    refute Keyword.has_key?(staff, :domain)
    refute Keyword.has_key?(admin, :domain)
  end

  test "staff login token for another tenant cannot create a session", %{conn: conn, staff: staff} do
    tokenized = Account.ensure_login_token(staff)
    {:ok, other} = Tenants.create_tenant(%{name: "Other", slug: "other"})
    {:ok, _} = Tenants.add_host(other.id, "other.example.com")

    response =
      get(%{conn | host: "other.example.com"}, "/app/login/verify/#{tokenized.login_token}")

    assert html_response(response, 200) =~ "Invalid or expired login link"
    assert Account.login_token_valid?(Repo.get!(StaffAccount, staff.id))
  end

  test "connected authentication uses transport host instead of the client navigation URL", %{
    conn: conn,
    staff: staff
  } do
    {:ok, foreign} = Tenants.create_tenant(%{name: "Foreign", slug: "foreign"})
    {:ok, _} = Tenants.add_host(foreign.id, "foreign.example.com")

    conn =
      %{conn | host: "workspace.example.com"}
      |> init_test_session(%{host_tenant_id: staff.tenant_id})
      |> put_staff_session(staff)

    conn = put_private(conn, :live_view_connect_info, %{uri: %URI{host: "foreign.example.com"}})
    assert {:error, {:redirect, %{to: "/app/login"}}} = live(conn, "/app")
  end

  test "an installation transport cannot authenticate staff through a stale tenant host mapping",
       %{
         conn: conn,
         staff: staff,
         tenant: tenant
       } do
    Repo.insert!(%Custyard.TenantHost{tenant_id: tenant.id, hostname: Tenants.app_host()})

    conn =
      %{conn | host: "workspace.example.com"}
      |> init_test_session(%{})
      |> put_staff_session(staff)
      |> put_private(:live_view_connect_info, %{uri: %URI{host: Tenants.app_host()}})

    assert {:error, {:redirect, %{to: "/app/login"}}} = live(conn, "/app")
    assert %{status: 404} = get(%{conn | host: Tenants.app_host()}, "/app")
  end

  test "logged-in headers distinguish installation identity and tenant staff", %{
    conn: conn,
    staff: staff,
    admin: admin,
    tenant: tenant
  } do
    staff_conn =
      %{conn | host: "workspace.example.com"}
      |> init_test_session(%{})
      |> put_staff_session(staff)

    {:ok, staff_view, staff_html} = live(staff_conn, "/app")
    assert has_element?(staff_view, "[data-testid=staff-identity]", "Staff · #{staff.email}")
    assert staff_html =~ tenant.name
    assert staff_html =~ "Instance admin sign in"
    refute staff_html =~ admin.email

    admin_conn =
      %{build_conn() | host: Tenants.app_host()}
      |> init_test_session(%{
        instance_admin_id: admin.id,
        instance_admin_claim: admin.session_claim
      })

    {:ok, admin_view, admin_html} = live(admin_conn, "/admin")

    assert has_element?(
             admin_view,
             "[data-testid=instance-admin-identity]",
             "Instance admin · #{admin.email}"
           )

    assert admin_html =~ "Staff sign in to #{tenant.name}"
    refute has_element?(admin_view, "[data-testid=staff-identity]")
  end

  test "email domains do not grant installation authority", %{tenant: tenant, admin: admin} do
    assert {:ok, staff} =
             %StaffAccount{}
             |> StaffAccount.changeset(%{
               tenant_id: tenant.id,
               email: admin.email,
               role: "agent"
             })
             |> Repo.insert()

    assert staff.email == admin.email
    assert staff.role == "agent"
    assert Custyard.Scope.for_staff(staff, tenant).staff_id == staff.id
  end
end
