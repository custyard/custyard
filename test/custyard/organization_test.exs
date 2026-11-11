defmodule Custyard.OrganizationTest do
  use Custyard.DataCase, async: true
  import Custyard.Factory
  alias Custyard.Organization

  test "manual customers receive an independent identity and tenant is mandatory" do
    tenant = insert_tenant()
    changeset = Organization.changeset(%Organization{}, %{tenant_id: tenant.id, name: "Acme"})
    assert changeset.valid?
    assert get_field(changeset, :identity_kind) == :manual
    assert is_binary(get_field(changeset, :identity_value))
    refute Organization.changeset(%Organization{}, %{name: "Acme"}).valid?
  end

  test "domain and email identities are unique within a tenant" do
    tenant = insert_tenant()

    attrs = %{
      tenant_id: tenant.id,
      name: "Acme",
      identity_kind: :domain,
      identity_value: "acme.example",
      domain: "acme.example"
    }

    assert {:ok, _} = %Organization{} |> Organization.changeset(attrs) |> Repo.insert()
    assert {:error, changeset} = %Organization{} |> Organization.changeset(attrs) |> Repo.insert()
    assert changeset.errors != []
    other = insert_tenant()

    assert {:ok, _} =
             %Organization{}
             |> Organization.changeset(Map.put(attrs, :tenant_id, other.id))
             |> Repo.insert()
  end

  test "editing a business domain updates its canonical identity" do
    org = insert_organization(domain: "old.example")

    assert {:ok, updated} =
             org |> Organization.changeset(%{domain: "New.Example"}) |> Repo.update()

    assert updated.domain == "new.example"
    assert updated.identity_value == "new.example"
  end

  test "customers cannot move between tenants" do
    org = insert_organization()
    other = insert_tenant()
    refute Organization.changeset(org, %{tenant_id: other.id}).valid?
  end

  test "customer schema contains no workspace settings or portal secret" do
    fields = Organization.__schema__(:fields)

    for field <- [
          :token,
          :intake_key,
          :logo_url,
          :primary_color,
          :secondary_color,
          :custom_domain,
          :lettermint_project_id
        ],
        do: refute(field in fields)
  end
end
