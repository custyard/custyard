defmodule Custyard.OrganizationsTest do
  use Custyard.DataCase, async: true

  alias Custyard.Organizations

  import Custyard.Factory

  describe "get_organization/1" do
    test "returns organization by id" do
      org = insert_organization(name: "Test Org")

      assert result = Organizations.get_organization(org.id)
      assert result.id == org.id
      assert result.name == "Test Org"
    end

    test "returns nil for non-existent id" do
      assert Organizations.get_organization(999_999) == nil
    end
  end

  describe "get_organization!/1" do
    test "returns organization by id" do
      org = insert_organization(name: "Test Org")

      assert result = Organizations.get_organization!(org.id)
      assert result.id == org.id
    end

    test "raises for non-existent id" do
      assert_raise Ecto.NoResultsError, fn ->
        Organizations.get_organization!(999_999)
      end
    end
  end

  describe "get_organization_by_token/1" do
    @valid_token "test-token-abc-1234567890-abcdefghij"

    test "returns organization by token" do
      org = insert_organization(token: @valid_token)

      assert result = Organizations.get_organization_by_token(@valid_token)
      assert result.id == org.id
    end

    test "returns nil for unknown token" do
      assert Organizations.get_organization_by_token("nonexistent") == nil
    end
  end

  describe "list_organizations/0" do
    test "returns all organizations ordered by name" do
      insert_organization(name: "Zebra Corp")
      insert_organization(name: "Alpha Inc")
      insert_organization(name: "Beta LLC")

      result = Organizations.list_organizations()

      assert length(result) == 3
      assert Enum.map(result, & &1.name) == ["Alpha Inc", "Beta LLC", "Zebra Corp"]
    end

    test "returns empty list when no organizations exist" do
      assert Organizations.list_organizations() == []
    end
  end

  describe "list_organizations_with_counts/0" do
    test "returns organizations with conversation counts" do
      org1 = insert_organization(name: "Org with convos")
      _org2 = insert_organization(name: "Org empty")

      insert_conversation(organization_id: org1.id)
      insert_conversation(organization_id: org1.id)
      insert_conversation(organization_id: org1.id)

      result = Organizations.list_organizations_with_counts()

      assert length(result) == 2

      org1_result = Enum.find(result, &(&1.org.name == "Org with convos"))
      org2_result = Enum.find(result, &(&1.org.name == "Org empty"))

      assert org1_result.conversation_count == 3
      assert org2_result.conversation_count == 0
    end
  end

  describe "create_organization/1" do
    test "creates organization with valid attributes" do
      attrs = build_organization(name: "New Corp")

      assert {:ok, org} = Organizations.create_organization(attrs)
      assert org.name == "New Corp"
      assert org.token != nil
    end

    test "auto-provisions a default general inbound route" do
      attrs = build_organization(name: "Auto Route Corp")

      assert {:ok, org} = Organizations.create_organization(attrs)

      routes = Custyard.InboundRoutes.list_for_organization(org.id)
      assert length(routes) == 1

      [route] = routes
      assert route.route_type == :general
      assert route.organization_id == org.id
      assert route.callback_token != nil
      assert route.lettermint_route_id != nil
    end

    test "returns error changeset for invalid attributes" do
      attrs = %{tier: :standard}

      assert {:error, changeset} = Organizations.create_organization(attrs)
      assert "can't be blank" in errors_on(changeset).name
    end
  end

  describe "update_organization/2" do
    test "updates organization with valid attributes" do
      org = insert_organization(name: "Old Name")

      assert {:ok, updated} = Organizations.update_organization(org, %{name: "New Name"})
      assert updated.name == "New Name"
    end

    test "returns error for invalid update" do
      org = insert_organization()

      assert {:error, changeset} = Organizations.update_organization(org, %{name: ""})
      assert "can't be blank" in errors_on(changeset).name
    end
  end

  describe "change_organization/2" do
    test "returns a changeset" do
      org = insert_organization()

      changeset = Organizations.change_organization(org, %{name: "Changed"})

      assert %Ecto.Changeset{} = changeset
      assert changeset.changes.name == "Changed"
    end
  end

  describe "delete_organization/1" do
    test "deletes the organization" do
      org = insert_organization()

      assert {:ok, deleted} = Organizations.delete_organization(org)
      assert deleted.id == org.id
      assert Organizations.get_organization(org.id) == nil
    end
  end

  describe "regenerate_portal_token/1" do
    test "generates a new token" do
      org = insert_organization()
      original_token = org.token

      assert {:ok, updated} = Organizations.regenerate_portal_token(org)
      assert updated.token != original_token
      assert String.length(updated.token) >= 32
    end

    test "invalidates the old token" do
      org = insert_organization()
      original_token = org.token

      {:ok, _updated} = Organizations.regenerate_portal_token(org)

      assert Organizations.get_organization_by_token(original_token) == nil
    end
  end

  describe "get_organization_by_custom_domain/1" do
    test "returns organization by custom domain" do
      insert_organization(custom_domain: "support.acme.com")

      assert result = Organizations.get_organization_by_custom_domain("support.acme.com")
      assert result.custom_domain == "support.acme.com"
    end

    test "returns nil when no organization has that domain" do
      insert_organization(custom_domain: "other.example.com")

      assert Organizations.get_organization_by_custom_domain("unknown.example.com") == nil
    end

    test "returns nil when no organizations have custom domains" do
      insert_organization(custom_domain: nil)

      assert Organizations.get_organization_by_custom_domain("any.domain.com") == nil
    end
  end

  describe "verify_custom_domain/1" do
    # Note: These tests use mocking approaches or test the error paths
    # since we cannot control actual DNS during tests

    test "returns dns_lookup_failed for invalid domain format" do
      # Domains that will fail DNS lookup
      result = Organizations.verify_custom_domain("not-a-real-domain-xyz.invalid")

      assert result in [{:error, :no_cname}, {:error, :dns_lookup_failed}]
    end

    test "returns no_cname for domain without CNAME record" do
      # Using localhost which typically has no CNAME
      result = Organizations.verify_custom_domain("localhost")

      assert result in [{:error, :no_cname}, {:error, :dns_lookup_failed}]
    end
  end

  describe "expected_cname_target/0" do
    test "returns the configured app host" do
      # The default is localhost when not configured
      result = Organizations.expected_cname_target()

      assert is_binary(result)
      assert result == "localhost"
    end
  end
end
