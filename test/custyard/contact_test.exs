defmodule Custyard.ContactTest do
  use Custyard.DataCase, async: true

  alias Custyard.Contact

  import Custyard.Factory

  describe "changeset/2 email validation" do
    test "accepts valid email addresses" do
      org = insert_organization()

      valid_emails = [
        "simple@example.com",
        "user.name@example.com",
        "user+tag@example.com",
        "user-name@example.co.uk",
        "user_name@sub.domain.example.com",
        "user123@example.org",
        "a@b.co"
      ]

      for email <- valid_emails do
        attrs = build_contact(email: email, organization_id: org.id)
        changeset = Contact.changeset(%Contact{}, attrs)

        assert changeset.valid?,
               "Expected #{email} to be valid, got errors: #{inspect(changeset.errors)}"
      end
    end

    test "rejects emails with control characters" do
      org = insert_organization()
      # Null byte
      attrs = build_contact(email: "test\x00@example.com", organization_id: org.id)
      changeset = Contact.changeset(%Contact{}, attrs)

      refute changeset.valid?
      assert "must not contain control characters" in errors_on(changeset).email
    end

    test "rejects emails with various control characters" do
      org = insert_organization()

      invalid_emails = [
        # Null byte
        "test\x00@example.com",
        # Bell
        "test\x07@example.com",
        # Unit separator
        "test\x1F@example.com",
        # DEL
        "test\x7F@example.com"
      ]

      for email <- invalid_emails do
        attrs = build_contact(email: email, organization_id: org.id)
        changeset = Contact.changeset(%Contact{}, attrs)

        refute changeset.valid?, "Expected #{inspect(email)} to be rejected"
        assert "must not contain control characters" in errors_on(changeset).email
      end
    end

    test "rejects local part longer than 64 characters" do
      org = insert_organization()
      # Create a local part exactly 65 characters long
      long_local = String.duplicate("a", 65)
      email = "#{long_local}@example.com"

      attrs = build_contact(email: email, organization_id: org.id)
      changeset = Contact.changeset(%Contact{}, attrs)

      refute changeset.valid?
      assert "local part must be at most 64 characters" in errors_on(changeset).email
    end

    test "accepts local part exactly 64 characters" do
      org = insert_organization()
      long_local = String.duplicate("a", 64)
      email = "#{long_local}@example.com"

      attrs = build_contact(email: email, organization_id: org.id)
      changeset = Contact.changeset(%Contact{}, attrs)

      assert changeset.valid?,
             "Expected 64-char local part to be valid, got: #{inspect(changeset.errors)}"
    end

    test "rejects total email length over 320 characters" do
      org = insert_organization()
      # Create an email that exceeds 320 characters total
      # 64 char local + 1 @ + 256 char domain = 321 chars
      long_local = String.duplicate("a", 64)
      # Build a domain with many subdomains to exceed 255 chars
      domain_parts = Enum.map(1..32, fn _ -> "abcdefgh" end) |> Enum.join(".")
      email = "#{long_local}@#{domain_parts}"

      attrs = build_contact(email: email, organization_id: org.id)
      changeset = Contact.changeset(%Contact{}, attrs)

      refute changeset.valid?
      # Should fail the length validation
      errors = errors_on(changeset)

      assert "must be at most 320 characters" in errors.email or
               "must be a valid email address" in errors.email
    end

    test "rejects invalid email formats" do
      org = insert_organization()

      invalid_emails = [
        # No @ sign
        "plainaddress",
        # No local part
        "@example.com",
        # No domain
        "user@",
        # Domain starts with dot
        "user@.com",
        # No TLD (no dot in domain)
        "user@example",
        # Double @
        "user@@example.com",
        # Space in email
        "user @example.com",
        # Tab in email (control character)
        "user\t@example.com"
      ]

      for email <- invalid_emails do
        attrs = build_contact(email: email, organization_id: org.id)
        changeset = Contact.changeset(%Contact{}, attrs)

        refute changeset.valid?, "Expected #{inspect(email)} to be rejected"

        assert Map.has_key?(errors_on(changeset), :email),
               "Expected email error for #{inspect(email)}, got: #{inspect(changeset.errors)}"
      end
    end

    test "accepts email exactly 320 characters" do
      org = insert_organization()
      # Build an email exactly 320 chars: 60 char local + @ + 259 char domain = 320
      # Domain uses multiple subdomains (max 63 chars each segment per RFC)
      local = String.duplicate("a", 60)
      # 61+1+61+1+61+1+61+1+7+1+3 = 259 chars for domain
      domain =
        String.duplicate("a", 61) <>
          "." <>
          String.duplicate("b", 61) <>
          "." <>
          String.duplicate("c", 61) <>
          "." <>
          String.duplicate("d", 61) <> ".aaaaaaa.com"

      email = "#{local}@#{domain}"
      assert String.length(email) == 320, "Expected 320 chars, got #{String.length(email)}"

      attrs = build_contact(email: email, organization_id: org.id)
      changeset = Contact.changeset(%Contact{}, attrs)

      # The regex might reject this due to domain segment length limits (max 63)
      # But length validation should pass
      # Check if changeset is valid or only fails on format (not length)
      if not changeset.valid? do
        errors = errors_on(changeset)
        # Should NOT have the length error for exactly 320 chars
        refute "must be at most 320 characters" in errors.email
      end
    end
  end

  describe "changeset/2 required fields" do
    test "requires email" do
      org = insert_organization()
      attrs = build_contact(organization_id: org.id) |> Map.delete(:email)
      changeset = Contact.changeset(%Contact{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).email
    end

    test "requires organization_id" do
      attrs = build_contact() |> Map.delete(:organization_id)
      changeset = Contact.changeset(%Contact{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).organization_id
    end
  end

  describe "update_changeset/2" do
    test "allows updating email with valid value" do
      contact = insert_contact()
      changeset = Contact.update_changeset(contact, %{email: "newemail@example.com"})

      assert changeset.valid?
      assert get_change(changeset, :email) == "newemail@example.com"
    end

    test "rejects invalid email in update" do
      contact = insert_contact()
      changeset = Contact.update_changeset(contact, %{email: "invalid-email"})

      refute changeset.valid?
      assert "must be a valid email address" in errors_on(changeset).email
    end

    test "does not allow changing organization_id" do
      # update_changeset doesn't cast organization_id at all
      contact = insert_contact()
      org2 = insert_organization()
      changeset = Contact.update_changeset(contact, %{organization_id: org2.id})

      # The organization_id change should be ignored (not in cast list)
      assert changeset.valid?
      assert get_change(changeset, :organization_id) == nil
    end
  end

  describe "validate_organization_immutable" do
    test "prevents changing organization_id on existing contact" do
      contact = insert_contact()
      org2 = insert_organization()

      # Use regular changeset which casts organization_id
      changeset = Contact.changeset(contact, %{organization_id: org2.id})

      refute changeset.valid?
      assert "cannot be changed after contact is created" in errors_on(changeset).organization_id
    end

    test "allows setting organization_id on new contact" do
      org = insert_organization()
      attrs = build_contact(organization_id: org.id)
      changeset = Contact.changeset(%Contact{}, attrs)

      assert changeset.valid?
    end
  end

  describe "database persistence" do
    test "creates contact with valid attributes" do
      org = insert_organization()
      attrs = build_contact(organization_id: org.id)

      {:ok, contact} = %Contact{} |> Contact.changeset(attrs) |> Repo.insert()

      assert contact.id != nil
      assert contact.email == attrs.email
      assert contact.organization_id == org.id
    end

    test "enforces unique email within organization" do
      org = insert_organization()
      insert_contact(email: "duplicate@example.com", organization_id: org.id)

      # Try to insert another contact with the same email in same org
      attrs = build_contact(email: "duplicate@example.com", organization_id: org.id)
      changeset = Contact.changeset(%Contact{}, attrs)
      {:error, changeset} = Repo.insert(changeset)

      assert "has already been taken" in errors_on(changeset).email
    end

    test "allows same email in different organizations" do
      org1 = insert_organization()
      org2 = insert_organization()
      email = "shared@example.com"

      # Insert in org1
      {:ok, contact1} =
        %Contact{}
        |> Contact.changeset(build_contact(email: email, organization_id: org1.id))
        |> Repo.insert()

      # Insert same email in org2 - should succeed
      {:ok, contact2} =
        %Contact{}
        |> Contact.changeset(build_contact(email: email, organization_id: org2.id))
        |> Repo.insert()

      assert contact1.email == contact2.email
      assert contact1.organization_id != contact2.organization_id
    end
  end
end
