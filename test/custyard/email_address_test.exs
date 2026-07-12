defmodule Custyard.EmailAddressTest do
  use ExUnit.Case, async: true

  alias Custyard.EmailAddress

  # Schemaless changeset for exercising the shared validator directly
  defp email_changeset(email) do
    {%{}, %{email: :string}}
    |> Ecto.Changeset.cast(%{email: email}, [:email])
    |> EmailAddress.validate_email(:email)
  end

  describe "validate_email/2" do
    test "accepts valid addresses" do
      for email <- ["a@b.co", "first.last+tag@sub.example.com", "x_y-z@example.io"] do
        assert email_changeset(email).valid?, "expected #{inspect(email)} to be valid"
      end
    end

    test "rejects malformed addresses" do
      for email <- ["plain", "a@b", "a b@c.com", "a@@b.com"] do
        refute email_changeset(email).valid?, "expected #{inspect(email)} to be invalid"
      end
    end

    test "rejects control characters" do
      changeset = email_changeset("bad\x00@example.com")
      refute changeset.valid?
      assert {:email, {"must not contain control characters", []}} in changeset.errors
    end

    test "rejects local parts over 64 characters" do
      changeset = email_changeset(String.duplicate("a", 65) <> "@example.com")
      refute changeset.valid?
      assert {:email, {"local part must be at most 64 characters", []}} in changeset.errors
    end

    test "skips validation when the field has no change" do
      changeset =
        {%{}, %{email: :string}}
        |> Ecto.Changeset.cast(%{}, [:email])
        |> EmailAddress.validate_email(:email)

      assert changeset.valid?
    end
  end

  describe "normalize/1" do
    test "trims and downcases" do
      assert EmailAddress.normalize("  MiXeD@Example.COM ") == "mixed@example.com"
    end

    test "passes non-binary input through unchanged" do
      assert EmailAddress.normalize(nil) == nil
      assert EmailAddress.normalize(123) == 123
    end
  end

  describe "regex/0" do
    test "is the shared contact email format" do
      assert Regex.match?(EmailAddress.regex(), "person@example.com")
      refute Regex.match?(EmailAddress.regex(), "person@localhost")
    end
  end
end
