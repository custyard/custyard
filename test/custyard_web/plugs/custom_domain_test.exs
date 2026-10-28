defmodule CustyardWeb.Plugs.CustomDomainTest do
  use Custyard.DataCase
  import Plug.Test
  import Custyard.Factory
  alias Custyard.{InstanceAdmins, Tenants}
  alias CustyardWeb.Plugs.CustomDomain

  test "registered host resolves tenant without rewriting paths" do
    tenant = insert_tenant()
    {:ok, _} = Tenants.add_host(tenant.id, "support.example.com")
    result = CustomDomain.call(%{conn(:get, "/app/projects") | host: "SUPPORT.EXAMPLE.COM"}, [])
    assert result.assigns.host_tenant.id == tenant.id
    assert result.request_path == "/app/projects"
    refute result.halted
  end

  test "unknown host is rejected and installation console remains reachable" do
    assert %{status: 404, halted: true} =
             CustomDomain.call(%{conn(:get, "/") | host: "unknown.example.com"}, [])

    result = CustomDomain.call(%{conn(:get, "/admin/login") | host: Tenants.app_host()}, [])
    assert result.assigns.installation_host
    refute result.halted
  end

  test "suspended hosts block tenant pages but accept authenticated callback processing" do
    tenant = insert_tenant()
    {:ok, _} = Tenants.add_host(tenant.id, "support.example.com")
    {:created, admin} = InstanceAdmins.create_admin("instance@example.com")
    {:ok, _} = Tenants.set_status(admin, tenant.id, "suspended")

    assert %{status: 403, halted: true} =
             CustomDomain.call(%{conn(:get, "/app/login") | host: "support.example.com"}, [])

    for path <- ["/api/webhook/route/token", "/api/webhook/email-status/lettermint/token"] do
      result = CustomDomain.call(%{conn(:post, path) | host: "support.example.com"}, [])
      refute result.halted
    end
  end
end
