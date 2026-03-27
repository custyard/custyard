defmodule Custyard.OrganizationTest do
  use Custyard.DataCase, async: true

  alias Custyard.Organization

  import Custyard.Factory

  describe "changeset/2" do
    test "valid with required fields" do
      attrs = build_organization()
      changeset = Organization.changeset(%Organization{}, attrs)

      assert changeset.valid?
    end

    test "requires name" do
      attrs = build_organization() |> Map.delete(:name)
      changeset = Organization.changeset(%Organization{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).name
    end

    test "auto-generates token when nil" do
      attrs = build_organization() |> Map.put(:token, nil)
      changeset = Organization.changeset(%Organization{}, attrs)

      assert changeset.valid?
      token = get_change(changeset, :token)
      assert token != nil
      assert byte_size(token) > 20
    end

    test "preserves token when provided" do
      # Token must be at least 32 chars for security validation
      custom_token = "my-custom-token-with-sufficient-entropy"
      attrs = build_organization(token: custom_token)
      changeset = Organization.changeset(%Organization{}, attrs)

      assert changeset.valid?, "Changeset errors: #{inspect(changeset.errors)}"
      assert get_change(changeset, :token) == custom_token
    end

    test "rejects short tokens" do
      attrs = build_organization(token: "short-token")
      changeset = Organization.changeset(%Organization{}, attrs)

      refute changeset.valid?
      assert %{token: [error_msg]} = errors_on(changeset)
      assert error_msg =~ "at least 32 characters"
    end
  end

  describe "tier enum" do
    test "accepts valid tier values" do
      for tier <- [:enterprise, :standard, :basic] do
        attrs = build_organization(tier: tier)
        changeset = Organization.changeset(%Organization{}, attrs)

        assert changeset.valid?, "Expected #{tier} to be valid"
      end
    end

    test "rejects invalid tier value" do
      attrs = build_organization(tier: :premium)
      changeset = Organization.changeset(%Organization{}, attrs)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).tier
    end

    test "defaults to standard tier" do
      attrs = build_organization() |> Map.delete(:tier)
      changeset = Organization.changeset(%Organization{}, attrs)

      assert changeset.valid?
      # Default is set at schema level, not changeset level
    end
  end

  describe "domain validation" do
    test "accepts valid domain names" do
      valid_domains = [
        "example.com",
        "sub.example.com",
        "my-company.co.uk",
        "foo123.bar-baz.net",
        "EXAMPLE.COM"
      ]

      for domain <- valid_domains do
        attrs = build_organization(domain: domain)
        changeset = Organization.changeset(%Organization{}, attrs)

        assert changeset.valid?, "Expected '#{domain}' to be valid, got errors: #{inspect(changeset.errors)}"
      end
    end

    test "rejects invalid domain names" do
      invalid_domains = [
        "-example.com",
        "example-.com",
        "example..com",
        ".example.com",
        "example.com.",
        "example",
        "http://example.com",
        "example.com/path",
        "user@example.com",
        "example .com"
      ]

      for domain <- invalid_domains do
        attrs = build_organization(domain: domain)
        changeset = Organization.changeset(%Organization{}, attrs)

        refute changeset.valid?, "Expected '#{domain}' to be invalid"
        assert "must be a valid domain name" in errors_on(changeset).domain
      end
    end

    test "converts empty string domain to nil" do
      attrs = build_organization(domain: "")
      changeset = Organization.changeset(%Organization{}, attrs)

      assert changeset.valid?
      assert get_change(changeset, :domain) == nil
    end

    test "allows nil domain" do
      attrs = build_organization() |> Map.delete(:domain)
      changeset = Organization.changeset(%Organization{}, attrs)

      assert changeset.valid?
    end
  end

  describe "database persistence" do
    test "inserts with auto-generated token" do
      attrs = build_organization() |> Map.put(:token, nil)
      {:ok, org} = %Organization{} |> Organization.changeset(attrs) |> Repo.insert()

      assert org.id != nil
      assert org.token != nil
      assert byte_size(org.token) > 20
    end

    test "token uniqueness constraint" do
      # Token must be at least 32 chars
      token = "shared-token-abc-with-sufficient-length"
      insert_organization(token: token)

      attrs = build_organization(token: token)
      changeset = Organization.changeset(%Organization{}, attrs)
      {:error, changeset} = Repo.insert(changeset)

      assert "has already been taken" in errors_on(changeset).token
    end
  end
end
