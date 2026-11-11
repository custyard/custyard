defmodule CustyardWeb.OriginValidatorTest do
  use Custyard.DataCase
  import Custyard.Factory
  alias Custyard.Tenants
  alias CustyardWeb.OriginValidator

  test "origins must belong to explicit hostname registry or installation" do
    tenant = insert_tenant()
    {:ok, _} = Tenants.add_host(tenant.id, "support.example.com")
    assert OriginValidator.check_origin("https://support.example.com")
    assert OriginValidator.check_origin?(%URI{host: "SUPPORT.EXAMPLE.COM"}, [])
    assert OriginValidator.check_origin("https://" <> Tenants.app_host())
    refute OriginValidator.check_origin("https://nested.support.example.com")
    refute OriginValidator.check_origin("https://unknown.example.com")
    refute OriginValidator.check_origin(nil)
    refute OriginValidator.check_origin?(%URI{}, [])
    assert "//support.example.com" in OriginValidator.list_valid_origins()
  end
end
