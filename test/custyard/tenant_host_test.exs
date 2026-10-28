defmodule Custyard.TenantHostTest do
  use Custyard.DataCase, async: true
  alias Custyard.{Organizations, Tenants}

  test "default tenant identity and reserved hostnames cannot be reassigned" do
    default = Tenants.default_tenant()
    assert {:error, _} = Tenants.update_tenant(default, %{slug: "renamed"})
    assert Tenants.default_tenant().id == default.id

    for domain <- [Tenants.app_host(), "foreign." <> Tenants.app_host()] do
      assert {:error, _} =
               Tenants.create_tenant(%{
                 name: "Collision",
                 slug: "collision",
                 custom_domain: domain
               })
    end
  end

  test "tenant and legacy customer hostnames cannot shadow one another" do
    {:ok, tenant} =
      Tenants.create_tenant(%{
        name: "Atlas",
        slug: "host-atlas",
        custom_domain: "support.atlas.example"
      })

    assert {:error, _} =
             Organizations.create_organization(%{
               name: "Collision",
               custom_domain: tenant.custom_domain
             })

    assert {:error, _} =
             Organizations.create_organization(%{
               name: "Collision",
               custom_domain: "host-atlas." <> Tenants.app_host()
             })

    {:ok, org} =
      Organizations.create_organization(%{name: "Legacy", custom_domain: "legacy.example"})

    assert {:error, _} =
             Tenants.create_tenant(%{
               name: "Collision",
               slug: "collision",
               custom_domain: org.custom_domain
             })
  end

  test "tenant subdomain resolution removes only one instance-host suffix" do
    {:ok, tenant} = Tenants.create_tenant(%{name: "Exact host", slug: "exact-host"})
    host = Tenants.host(tenant)
    assert Tenants.resolve_host(host).id == tenant.id
    refute Tenants.resolve_host(host <> "." <> Tenants.app_host())
    refute Tenants.resolve_host("nested." <> host)
  end
end
