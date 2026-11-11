defmodule CustyardWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use CustyardWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint CustyardWeb.Endpoint

      use CustyardWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import CustyardWeb.ConnCase
    end
  end

  setup tags do
    Custyard.DataCase.setup_sandbox(tags)

    host =
      if tags[:explicit_tenant_hosts], do: Custyard.Tenants.app_host(), else: tenant_test_host()

    unless tags[:explicit_tenant_hosts] do
      tenant = Custyard.Factory.insert_tenant()
      Process.put(:factory_tenant_id, tenant.id)
      Custyard.Tenants.add_host(tenant.id, host)
      Custyard.Tenants.add_host(tenant.id, "www.example.com")
    end

    {:ok, conn: %{Phoenix.ConnTest.build_conn() | host: host}}
  end

  def tenant_test_host, do: "workspace.example.com"

  defp portal_staff_scope(tenant_id) do
    staff =
      Custyard.Repo.get_by(Custyard.StaffAccount, tenant_id: tenant_id, role: "admin") ||
        Custyard.Factory.insert_staff_account(tenant_id: tenant_id, role: "admin")

    Custyard.Scope.for_staff(staff, Custyard.Tenants.get_tenant!(tenant_id))
  end

  def portal_scope(%Custyard.Organization{} = organization),
    do: portal_staff_scope(organization.tenant_id)

  def portal_token(%Custyard.Organization{} = organization) do
    key = {:portal_token, organization.id}

    case Process.get(key) do
      nil ->
        {:ok, _, token} =
          Custyard.PortalCredentials.issue(
            portal_scope(organization),
            organization.id
          )

        Process.put(key, token)
        token

      token ->
        token
    end
  end

  @doc """
  Puts a staff session the way login does: the staff id plus the
  account's session claim (see
  `CustyardWeb.Live.StaffAuth.session_staff/2`). Takes a staff
  or an id; an id without a row gets no claim. The session must already
  be initialized (`init_test_session/2`).
  """
  def put_staff_session(conn, %Custyard.StaffAccount{} = staff) do
    tenant = Custyard.Tenants.get_tenant!(staff.tenant_id)
    host = Custyard.Tenants.host(tenant)

    host =
      if host do
        host
      else
        hostname = "tenant-#{tenant.id}.test"
        {:ok, _} = Custyard.Tenants.add_host(tenant.id, hostname)
        hostname
      end

    conn =
      if conn.host in [Custyard.Tenants.app_host(), "www.example.com", tenant_test_host()],
        do: %{conn | host: host},
        else: conn

    conn
    |> Plug.Conn.put_session(:staff_id, staff.id)
    |> Plug.Conn.put_session(:staff_claim, Custyard.StaffAccount.session_claim(staff))
  end

  def put_staff_session(conn, staff_id) do
    case Custyard.Repo.get(Custyard.StaffAccount, staff_id) do
      nil -> Plug.Conn.put_session(conn, :staff_id, staff_id)
      staff -> put_staff_session(conn, staff)
    end
  end
end
