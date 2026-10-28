defmodule Custyard.Email.SenderMatcherTest do
  use Custyard.DataCase, async: true
  alias Custyard.{Organization, Repo, Tenant}
  alias Custyard.Email.SenderMatcher

  defp tenant do
    %Tenant{}
    |> Tenant.changeset(%{
      name: "Workspace",
      slug: "workspace-#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end

  test "a business domain groups senders only within its receiving tenant" do
    a = tenant()
    b = tenant()

    assert {:ok, org_a, contact_a} =
             SenderMatcher.match_within_tenant("Alice <alice@acme.example>", a.id)

    assert {:ok, same_org, _} = SenderMatcher.match_within_tenant("Bob <bob@acme.example>", a.id)
    assert {:ok, org_b, contact_b} = SenderMatcher.match_within_tenant("alice@acme.example", b.id)
    assert same_org.id == org_a.id
    assert org_a.id != org_b.id
    assert contact_a.id != contact_b.id
    assert {org_a.identity_kind, org_a.identity_value} == {:domain, "acme.example"}
    assert contact_a.tenant_id == a.id
  end

  test "personal mailboxes create independent sender named customers" do
    tenant = tenant()

    assert {:ok, alice, _} =
             SenderMatcher.match_within_tenant("Alice Smith <alice@gmail.com>", tenant.id)

    assert {:ok, bob, _} = SenderMatcher.match_within_tenant("bob@gmail.com", tenant.id)
    assert alice.name == "Alice Smith"
    assert alice.identity_kind == :email
    assert alice.identity_value == "alice@gmail.com"
    assert alice.id != bob.id
    assert is_nil(alice.domain)
  end

  test "unidentifiable senders leave the customer unassigned" do
    tenant = tenant()
    assert {:ok, nil, nil} = SenderMatcher.match_within_tenant("unknown sender", tenant.id)
    assert Repo.aggregate(Organization, :count) == 0
  end

  test "ambiguous known contacts remain unassigned despite domain and channel hints" do
    tenant = tenant()

    first =
      %Organization{}
      |> Organization.changeset(%{tenant_id: tenant.id, name: "First"})
      |> Repo.insert!()

    second =
      %Organization{}
      |> Organization.changeset(%{tenant_id: tenant.id, name: "Second"})
      |> Repo.insert!()

    hint =
      %Organization{}
      |> Organization.changeset(%{
        tenant_id: tenant.id,
        name: "Domain and hint",
        domain: "acme.example"
      })
      |> Repo.insert!()

    for org <- [first, second] do
      %Custyard.Contact{}
      |> Custyard.Contact.changeset(%{
        tenant_id: tenant.id,
        organization_id: org.id,
        email: "shared@acme.example"
      })
      |> Repo.insert!()
    end

    assert :ambiguous = SenderMatcher.resolve_existing("shared@acme.example", tenant.id)

    assert {:ok, nil, nil} =
             SenderMatcher.match_within_tenant("shared@acme.example", tenant.id,
               organization_id: hint.id
             )

    assert Repo.aggregate(Organization, :count) == 3
  end

  test "a channel hint applies only to an unresolved sender and never crosses tenants" do
    a = tenant()
    b = tenant()

    hint =
      %Organization{}
      |> Organization.changeset(%{tenant_id: a.id, name: "Dedicated customer"})
      |> Repo.insert!()

    assert {:ok, actual, _} = SenderMatcher.match_within_tenant("alice@acme.example", a.id)

    assert {:ok, ^actual, _} =
             SenderMatcher.match_within_tenant("alice@acme.example", a.id,
               organization_id: hint.id
             )

    assert {:ok, hinted, _} =
             SenderMatcher.match_within_tenant("new@gmail.com", a.id, organization_id: hint.id)

    assert hinted.id == hint.id

    assert {:ok, other, _} =
             SenderMatcher.match_within_tenant("other@gmail.com", b.id, organization_id: hint.id)

    assert other.tenant_id == b.id
    assert other.id != hint.id
  end
end
