defmodule Custyard.EmailAddress do
  @moduledoc """
  Shared email address validation rules.

  Extracted from `Custyard.Contact` so contact and prospect email validation
  can never diverge. `Contact` delegates here; its behavior is unchanged.
  """

  import Ecto.Changeset

  # Basic email validation: local-part@domain.tld
  # More restrictive than RFC 5322 but catches common issues:
  # - Exactly one @ sign
  # - No whitespace or control characters
  # - Reasonable length limits (local <= 64, domain <= 255, total <= 320)
  # - At least one dot in domain
  @email_regex ~r/^[a-zA-Z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$/

  @doc "The email format regex shared by all email-bearing schemas."
  def regex, do: @email_regex

  @doc """
  Validate an email change on `field`.

  Applies exactly the historical `Custyard.Contact` rules: control-character
  rejection, format regex, and local part at most 64 characters. Skips
  validation when the field has no change.
  """
  def validate_email(changeset, field \\ :email) do
    case get_change(changeset, field) do
      nil ->
        changeset

      email ->
        cond do
          # Check for control characters or null bytes
          String.match?(email, ~r/[\x00-\x1F\x7F]/) ->
            add_error(changeset, field, "must not contain control characters")

          # Validate format with regex
          not Regex.match?(@email_regex, email) ->
            add_error(changeset, field, "must be a valid email address")

          # Validate local part length (before @)
          String.split(email, "@") |> hd() |> String.length() > 64 ->
            add_error(changeset, field, "local part must be at most 64 characters")

          true ->
            changeset
        end
    end
  end

  @doc """
  Normalize an email address for storage or lookup: trim, then downcase.
  """
  def normalize(email) when is_binary(email) do
    email |> String.trim() |> String.downcase()
  end

  def normalize(email), do: email
end
