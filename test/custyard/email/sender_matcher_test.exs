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

    test "matches email case-insensitively" do
      org = insert_organization(domain: "acme.example.com")
      contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")

      assert {:ok, matched_org, matched_contact} = SenderMatcher.match("ALICE@Acme.Example.COM")
      assert matched_org.id == org.id
      assert matched_contact.id == contact.id
    end

    test "extracts display name when creating contact from Name <email> format" do
      insert_organization(domain: "acme.example.com")

      assert {:ok, _org, contact} =
               SenderMatcher.match("Alice Smith <new-alice@acme.example.com>")

      assert contact.email == "new-alice@acme.example.com"
      assert contact.name == "Alice Smith"
    end

    test "handles quoted display names" do
      org = insert_organization(domain: "acme.example.com")
      contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")

      assert {:ok, matched_org, matched_contact} =
               SenderMatcher.match(~s("Smith, Alice" <alice@acme.example.com>))

      assert matched_org.id == org.id
      assert matched_contact.id == contact.id
    end

    test "address that cannot be stored as a contact files under the catchall with no contact" do
      assert {:ok, org, nil} = SenderMatcher.match("not-an-email")
      assert org.domain == "_unmatched_"
      assert Custyard.Repo.aggregate(Custyard.Contact, :count) == 0
    end

    @tag :skip
    test "address without a domain returns a changeset error" do
      # No domain -> unmatched-org fallback, but contact creation fails
      # email format validation. No contact row is created.
      assert {:error, %Ecto.Changeset{} = changeset} = SenderMatcher.match("not-an-email")
      assert {"must be a valid email address", _} = changeset.errors[:email]
      refute Custyard.Repo.get_by(Custyard.Contact, email: "not-an-email")
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

  describe "resolve/1" do
    import ExUnit.CaptureLog

    alias Custyard.{Contact, Organization, Repo}

    test "resolves an exact contact match" do
      org = insert_organization(domain: "acme.example.com")
      contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")

      assert {:contact, resolved} = SenderMatcher.resolve("alice@acme.example.com")
      assert resolved.id == contact.id
    end

    test "matches case-insensitively with surrounding whitespace" do
      org = insert_organization(domain: "acme.example.com")
      contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")

      assert {:contact, resolved} = SenderMatcher.resolve("  ALICE@Acme.Example.COM ")
      assert resolved.id == contact.id
    end

    test "multi-org ambiguity resolves to the oldest contact and logs a warning" do
      org_a = insert_organization(domain: "a.example.com")
      org_b = insert_organization(domain: "b.example.com")

      older = insert_contact(organization_id: org_a.id, email: "shared@example.com")
      _newer = insert_contact(organization_id: org_b.id, email: "shared@example.com")

      # Make the tie-break deterministic: age the first contact
      hour_ago =
        DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(c in Contact, where: c.id == ^older.id),
        set: [inserted_at: hour_ago]
      )

      log =
        capture_log(fn ->
          assert {:contact, resolved} = SenderMatcher.resolve("shared@example.com")
          assert resolved.id == older.id
        end)

      assert log =~ "sender_organization_ambiguous"
      refute log =~ "shared@example.com"
    end

    test "resolves from Name <email> format" do
      org = insert_organization(domain: "acme.example.com")
      contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")

      assert {:contact, resolved} =
               SenderMatcher.resolve("Alice Smith <alice@acme.example.com>")

      assert resolved.id == contact.id
    end

    test "falls back to organization-by-domain" do
      org = insert_organization(domain: "widgets.example.com")

      assert {:organization, resolved} = SenderMatcher.resolve("newcomer@widgets.example.com")
      assert resolved.id == org.id
    end

    test "never resolves to the _unmatched_ sentinel organization" do
      insert_organization(domain: "_unmatched_", name: "Unmatched Senders")

      assert SenderMatcher.resolve("someone@_unmatched_") == :none
    end

    test "never resolves a contact inside the sentinel organization" do
      sentinel = insert_organization(domain: "_unmatched_", name: "Unmatched Senders")
      insert_contact(organization_id: sentinel.id, email: "drifter@nowhere.example.net")

      assert SenderMatcher.resolve("drifter@nowhere.example.net") == :none
    end

    test "a sentinel-org contact falls through to organization-by-domain" do
      sentinel = insert_organization(domain: "_unmatched_", name: "Unmatched Senders")
      insert_contact(organization_id: sentinel.id, email: "early-bird@widgets.example.com")
      org = insert_organization(domain: "widgets.example.com")

      assert {:organization, resolved} = SenderMatcher.resolve("early-bird@widgets.example.com")
      assert resolved.id == org.id
    end

    test "resolves contacts in organizations without a domain" do
      org = insert_organization(domain: nil)
      contact = insert_contact(organization_id: org.id, email: "solo@freemail.example.net")

      assert {:contact, resolved} = SenderMatcher.resolve("solo@freemail.example.net")
      assert resolved.id == contact.id
    end

    test "returns :none for unknown senders" do
      assert SenderMatcher.resolve("stranger@nowhere.example.net") == :none
    end

    test "returns :none for addresses without a domain" do
      assert SenderMatcher.resolve("not-an-email") == :none
    end

    test "never creates rows" do
      org_count = Repo.aggregate(Organization, :count)
      contact_count = Repo.aggregate(Contact, :count)

      assert SenderMatcher.resolve("stranger@nowhere.example.net") == :none

      assert Repo.aggregate(Organization, :count) == org_count
      assert Repo.aggregate(Contact, :count) == contact_count
    end
  end

  describe "senders without a storable address" do
    test "match_within_org/2 resolves a Slack user id to the organization with no contact" do
      org = insert_organization()

      assert {:ok, matched_org, nil} = SenderMatcher.match_within_org("U12345", org.id)
      assert matched_org.id == org.id
      assert Custyard.Repo.aggregate(Custyard.Contact, :count) == 0
    end

    test "match_within_org/2 tolerates a missing, blank or address-less From" do
      org = insert_organization()

      assert {:ok, _org, nil} = SenderMatcher.match_within_org(nil, org.id)
      assert {:ok, _org, nil} = SenderMatcher.match_within_org("", org.id)
      assert {:ok, _org, nil} = SenderMatcher.match_within_org("Alice <>", org.id)
    end

    test "match_within_org/2 still matches and creates real addresses" do
      org = insert_organization()

      assert {:ok, _org, contact} =
               SenderMatcher.match_within_org("Alice <Alice@Example.com>", org.id)

      assert contact.email == "alice@example.com"
      assert contact.name == "Alice"
    end

    test "match/1 tolerates a missing From" do
      assert {:ok, org, nil} = SenderMatcher.match(nil)
      assert org.domain == "_unmatched_"
    end

    test "resolve/1 returns :none for a missing or unusable address" do
      assert SenderMatcher.resolve(nil) == :none
      assert SenderMatcher.resolve("U12345") == :none
    end
  end

  describe "extract_email/1" do
    test "returns the downcased address or nil" do
      assert SenderMatcher.extract_email("Bob <Bob@Example.com>") == "bob@example.com"
      assert SenderMatcher.extract_email("  bob@example.com ") == "bob@example.com"
      assert SenderMatcher.extract_email("Bob <>") == nil
      assert SenderMatcher.extract_email("U12345") == nil
      assert SenderMatcher.extract_email(nil) == nil
      assert SenderMatcher.extract_email(%{}) == nil
    end

    test "rejects an address a contact could not store" do
      # Matches the format regex, but the local part exceeds 64 characters.
      long_local = String.duplicate("a", 65) <> "@example.com"

      assert SenderMatcher.extract_email(long_local) == nil
      assert SenderMatcher.extract_email(String.duplicate("a", 64) <> "@example.com")
    end
  end
end
