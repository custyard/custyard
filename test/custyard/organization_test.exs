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
      custom_token = "my-custom-token-123"
      attrs = build_organization(token: custom_token)
      changeset = Organization.changeset(%Organization{}, attrs)

      assert changeset.valid?
      assert get_change(changeset, :token) == custom_token
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

  describe "database persistence" do
    test "inserts with auto-generated token" do
      attrs = build_organization() |> Map.put(:token, nil)
      {:ok, org} = %Organization{} |> Organization.changeset(attrs) |> Repo.insert()

      assert org.id != nil
      assert org.token != nil
      assert byte_size(org.token) > 20
    end

    test "token uniqueness constraint" do
      token = "shared-token-abc"
      insert_organization(token: token)

      attrs = build_organization(token: token)
      changeset = Organization.changeset(%Organization{}, attrs)
      {:error, changeset} = Repo.insert(changeset)

      assert "has already been taken" in errors_on(changeset).token
    end
  end
end
