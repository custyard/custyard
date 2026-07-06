defmodule Custyard.OrganizationsTest do
  use Custyard.DataCase, async: true

  alias Custyard.{AuditEvent, Contact, Conversation, Organizations, Prospect, Repo, Slugs}

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
      attrs = build_organization(name: "Auto Route Corp", lettermint_project_id: "lm_proj_test")

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

  describe "convert_prospect/2" do
    test "links the conversation to a new organization, keeping :public_intake provenance" do
      conversation = insert_conversation(source: :public_intake)
      insert_prospect(conversation_id: conversation.id)

      assert {:ok, converted} =
               Organizations.convert_prospect(conversation, %{name: "Acme Corp"})

      assert converted.source == :public_intake
      assert %{name: "Acme Corp"} = converted.organization
    end

    test "creates a contact from the prospect's captured email" do
      conversation = insert_conversation(source: :public_intake)

      insert_prospect(
        conversation_id: conversation.id,
        email: "buyer@acme.com",
        email_captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

      assert {:ok, converted} = Organizations.convert_prospect(conversation, %{name: "Acme Corp"})

      assert converted.contact_id
      contact = Repo.get_by!(Contact, organization_id: converted.organization_id)
      assert contact.email == "buyer@acme.com"
    end

    test "no captured email means no contact is created" do
      conversation = insert_conversation(source: :public_intake)
      insert_prospect(conversation_id: conversation.id)

      assert {:ok, converted} = Organizations.convert_prospect(conversation, %{name: "Acme Corp"})

      assert is_nil(converted.contact_id)
      assert Repo.aggregate(Contact, :count) == 0
    end

    test "promotes the conversation's confirmed slug claim to provisioned" do
      conversation = insert_conversation(source: :public_intake)
      insert_prospect(conversation_id: conversation.id)
      {:ok, _slug, token} = Slugs.claim("acme-hq", "buyer@example.com", conversation)
      {:ok, _confirmed} = Slugs.confirm(token)

      assert {:ok, converted} = Organizations.convert_prospect(conversation, %{name: "Acme Corp"})

      slug = Repo.get_by!(Custyard.Slug, conversation_id: conversation.id)
      assert slug.status == :provisioned
      assert slug.organization_id == converted.organization_id
    end

    test "an unconfirmed claim is not promoted, but conversion still succeeds" do
      conversation = insert_conversation(source: :public_intake)
      insert_prospect(conversation_id: conversation.id)
      {:ok, _slug, _token} = Slugs.claim("still-pending", "buyer@example.com", conversation)

      assert {:ok, _converted} = Organizations.convert_prospect(conversation, %{name: "Acme"})

      slug = Repo.get_by!(Custyard.Slug, conversation_id: conversation.id)
      assert slug.status == :claimed
    end

    test "does not revoke or rotate resume access" do
      conversation = insert_conversation(source: :public_intake)
      prospect = insert_prospect(conversation_id: conversation.id)

      assert {:ok, _converted} = Organizations.convert_prospect(conversation, %{name: "Acme"})

      reloaded = Repo.get!(Prospect, prospect.id)
      assert reloaded.resume_token_hash == prospect.resume_token_hash
      assert is_nil(reloaded.revoked_at)
    end

    test "records a :prospect_converted audit event" do
      conversation = insert_conversation(source: :public_intake)
      insert_prospect(conversation_id: conversation.id)

      assert {:ok, converted} = Organizations.convert_prospect(conversation, %{name: "Acme"})

      event =
        Repo.get_by!(AuditEvent,
          conversation_id: converted.id,
          event_type: :prospect_converted
        )

      assert event.organization_id == converted.organization_id
    end

    test "refuses a conversation already linked to an organization" do
      org = insert_organization()
      conversation = insert_conversation(organization_id: org.id, source: :public_intake)

      assert {:error, :not_convertible} =
               Organizations.convert_prospect(conversation, %{name: "Someone Else"})
    end

    test "refuses a non-public-intake conversation" do
      conversation = insert_conversation(organization_id: nil, source: :disambiguation)

      assert {:error, :not_convertible} =
               Organizations.convert_prospect(conversation, %{name: "Someone Else"})
    end

    test "a genuine step-2 failure compensates the organization, conversation stays unlinked" do
      conversation = insert_conversation(source: :public_intake)

      # Bypasses Prospect's changeset validation (mirrors the factory's raw-struct
      # discipline) to force a real Contact changeset error inside the transaction.
      insert_prospect(
        conversation_id: conversation.id,
        email: "not-an-email",
        email_captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

      assert {:error, %Ecto.Changeset{}} =
               Organizations.convert_prospect(conversation, %{name: "Bad Email Co"})

      assert Organizations.list_organizations() == []
      refute Repo.get!(Conversation, conversation.id).organization_id
    end

    test "a concurrent conversion attempt loses the race and compensates its organization" do
      conversation = insert_conversation(source: :public_intake)
      insert_prospect(conversation_id: conversation.id)

      assert {:ok, _first} = Organizations.convert_prospect(conversation, %{name: "First Corp"})

      # Simulates a second operator whose in-memory conversation struct was
      # loaded before the first conversion committed (organization_id still nil).
      assert {:error, :already_converted} =
               Organizations.convert_prospect(conversation, %{name: "Second Corp"})

      assert [remaining] = Organizations.list_organizations()
      assert remaining.name == "First Corp"
    end

    test "a Lettermint provisioning failure leaves no organization and the conversation unlinked" do
      conversation = insert_conversation(source: :public_intake)
      insert_prospect(conversation_id: conversation.id)

      original_config = Application.get_env(:custyard, :lettermint)
      Application.put_env(:custyard, :lettermint, client: Custyard.Lettermint.FailingMockClient)
      on_exit(fn -> Application.put_env(:custyard, :lettermint, original_config) end)

      assert {:error, %Ecto.Changeset{}} =
               Organizations.convert_prospect(conversation, %{
                 name: "Doomed Corp",
                 lettermint_project_id: "lm_doomed"
               })

      assert Organizations.list_organizations() == []
      refute Repo.get!(Conversation, conversation.id).organization_id
    end
  end
end
