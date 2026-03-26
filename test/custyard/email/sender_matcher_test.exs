defmodule Custyard.Email.SenderMatcherTest do
  use Custyard.DataCase, async: true

  alias Custyard.Email.SenderMatcher

  import Custyard.Factory

  describe "match/1" do
    test "matches contact by email" do
      org = insert_organization(domain: "acme.example.com")
      contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")

      assert {:ok, matched_org, matched_contact} = SenderMatcher.match("alice@acme.example.com")
      assert matched_org.id == org.id
      assert matched_contact.id == contact.id
    end

    test "creates contact for known domain" do
      org = insert_organization(domain: "acme.example.com")

      assert {:ok, matched_org, contact} = SenderMatcher.match("new-user@acme.example.com")
      assert matched_org.id == org.id
      assert contact.email == "new-user@acme.example.com"
    end

    test "creates unmatched org for unknown domain" do
      assert {:ok, org, contact} = SenderMatcher.match("unknown@random.test")
      assert org.domain == "_unmatched_"
      assert contact.email == "unknown@random.test"
    end
  end

  describe "match_within_org/2" do
    test "finds existing contact within org" do
      org = insert_organization(domain: "acme.example.com")
      contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")

      assert {:ok, matched_org, matched_contact} =
               SenderMatcher.match_within_org("alice@acme.example.com", org.id)

      assert matched_org.id == org.id
      assert matched_contact.id == contact.id
    end

    test "creates contact within specified org for unknown sender" do
      org = insert_organization(domain: "acme.example.com")

      assert {:ok, matched_org, contact} =
               SenderMatcher.match_within_org("new-person@other.com", org.id)

      assert matched_org.id == org.id
      assert contact.email == "new-person@other.com"
      assert contact.organization_id == org.id
    end

    test "scopes contact lookup to the specified org" do
      org1 = insert_organization(domain: "org1.example.com")
      org2 = insert_organization(domain: "org2.example.com")
      _contact1 = insert_contact(organization_id: org1.id, email: "shared@example.com")

      # Should NOT find org1's contact when searching in org2
      assert {:ok, matched_org, contact} =
               SenderMatcher.match_within_org("shared@example.com", org2.id)

      assert matched_org.id == org2.id
      assert contact.organization_id == org2.id
    end

    test "handles Name <email> format" do
      org = insert_organization(domain: "acme.example.com")
      contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")

      assert {:ok, _, matched_contact} =
               SenderMatcher.match_within_org("Alice Smith <alice@acme.example.com>", org.id)

      assert matched_contact.id == contact.id
    end
  end
end
