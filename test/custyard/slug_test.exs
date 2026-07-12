defmodule Custyard.SlugTest do
  use Custyard.DataCase, async: true

  alias Custyard.Auth.Token
  alias Custyard.Slug

  defp changeset(overrides) do
    attrs =
      Map.merge(
        %{
          slug: "acme-corp",
          email: "claimant@example.com",
          conversation_id: 1,
          expires_at: DateTime.add(DateTime.utc_now(), 72, :hour),
          confirmation_token_hash: Token.generate() |> elem(1)
        },
        Map.new(overrides)
      )

    Slug.claim_changeset(%Slug{}, attrs)
  end

  describe "normalization" do
    test "downcases and trims the slug before validation" do
      cs = changeset(slug: "  AcMe-Corp  ")

      assert cs.valid?
      assert get_field(cs, :slug) == "acme-corp"
    end

    test "downcases and trims the email" do
      cs = changeset(email: "  Claimant@EXAMPLE.com ")

      assert cs.valid?
      assert get_field(cs, :email) == "claimant@example.com"
    end

    test "a slug differing only in case validates against the reserved list" do
      cs = changeset(slug: "OPERATOR")

      refute cs.valid?
      assert "is reserved" in errors_on(cs).slug
    end
  end

  describe "format matrix" do
    test "accepts DNS-label-safe slugs" do
      for valid <- [
            "abc",
            "a1b",
            "123",
            "acme-corp",
            "a-b-c",
            "x" <> String.duplicate("y", 61) <> "z",
            "0-0"
          ] do
        cs = changeset(slug: valid)
        assert cs.valid?, "expected #{inspect(valid)} to be valid: #{inspect(cs.errors)}"
      end
    end

    test "rejects malformed slugs" do
      for invalid <- [
            # too short
            "ab",
            "a",
            "",
            # too long (64)
            "x" <> String.duplicate("y", 62) <> "z",
            # leading/trailing hyphen
            "-abc",
            "abc-",
            # illegal characters (uppercase is normalized away, so these
            # exercise the character class itself)
            "ab.c",
            "ab_c",
            "ab c",
            "ab@c",
            "ab\nc",
            "acmé"
          ] do
        cs = changeset(slug: invalid)
        refute cs.valid?, "expected #{inspect(invalid)} to be invalid"
        assert Keyword.has_key?(cs.errors, :slug)
      end
    end

    test "rejects the xn-- punycode prefix" do
      cs = changeset(slug: "xn--acme")

      refute cs.valid?
      assert "must not start with xn--" in errors_on(cs).slug
    end
  end

  describe "reserved words" do
    test "every router first-path-segment is unclaimable" do
      # Router scopes: /i, /r, /c, /api, /operator, /p. Endpoint paths:
      # /live, /phoenix, /dev, plus the static roots. The short ones also
      # fail the 3-char format floor; either way they must not validate.
      for segment <- ~w(i r c p api operator live phoenix dev assets fonts images uploads) do
        cs = changeset(slug: segment)
        refute cs.valid?, "expected router segment #{inspect(segment)} to be unclaimable"
        assert Keyword.has_key?(cs.errors, :slug)
      end
    end

    test "reserved infrastructure and product names are rejected" do
      for reserved <- ~w(www mail portal admin app static webhook webhooks login logout
                         signup support help status docs blog claim intake resume confirm
                         settings health smtp imap pop webmail email autodiscover autoconfig
                         postmaster hostmaster abuse security root system internal billing
                         noreply no-reply custyard unmatched) do
        cs = changeset(slug: reserved)
        refute cs.valid?, "expected #{inspect(reserved)} to be reserved"
        assert "is reserved" in errors_on(cs).slug
      end
    end

    test "the :additional_reserved_slugs config extends the list" do
      original = Application.get_env(:custyard, :additional_reserved_slugs)
      Application.put_env(:custyard, :additional_reserved_slugs, ["deploy-only"])

      on_exit(fn ->
        if original do
          Application.put_env(:custyard, :additional_reserved_slugs, original)
        else
          Application.delete_env(:custyard, :additional_reserved_slugs)
        end
      end)

      cs = changeset(slug: "deploy-only")
      refute cs.valid?
      assert "is reserved" in errors_on(cs).slug

      # And the code list still applies alongside it.
      assert "is reserved" in errors_on(changeset(slug: "www")).slug
    end
  end

  describe "email validation" do
    test "requires a valid email address" do
      cs = changeset(email: "not-an-email")

      refute cs.valid?
      assert "must be a valid email address" in errors_on(cs).email
    end

    test "rejects control characters" do
      cs = changeset(email: "a\r\nb@example.com")

      refute cs.valid?
      assert "must not contain control characters" in errors_on(cs).email
    end
  end

  describe "required fields" do
    test "slug, email, conversation, expiry, and token hash are all required" do
      cs = Slug.claim_changeset(%Slug{}, %{})

      errors = errors_on(cs)

      for field <- [:slug, :email, :conversation_id, :expires_at, :confirmation_token_hash] do
        assert "can't be blank" in Map.fetch!(errors, field)
      end
    end

    test "status is not castable — rows are born claimed" do
      cs = changeset(%{status: :provisioned})

      assert get_field(cs, :status) == :claimed
    end
  end
end
