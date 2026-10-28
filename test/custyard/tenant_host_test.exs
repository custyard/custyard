defmodule Custyard.TenantHostTest do
  use Custyard.DataCase
  alias Custyard.{Factory, Tenants}

  test "only explicit hostname registrations resolve" do
    tenant = Factory.insert_tenant(slug: "example")
    refute Tenants.resolve_host("example." <> Tenants.app_host())
    assert {:ok, _} = Tenants.add_host(tenant.id, "example." <> Tenants.app_host())
    assert Tenants.resolve_host("example." <> Tenants.app_host()).id == tenant.id
    refute Tenants.resolve_host("nested.example." <> Tenants.app_host())

    for hostname <- [
          "*.example.com",
          "..example.com",
          "-bad.example.com",
          "https://example.com",
          "example.com/path"
        ] do
      assert {:error, _} = Tenants.add_host(tenant.id, hostname)
    end
  end
end
