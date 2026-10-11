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
        case format_error(email) do
          nil -> changeset
          message -> add_error(changeset, field, message)
        end
    end
  end

  @max_length 320

  @doc """
  Whether `email` passes every rule a stored address must: `validate_email/2`
  and the #{@max_length}-character length limit `Custyard.Contact` applies.
  For callers that must know before an insert whether it can succeed.
  """
  def valid?(email) when is_binary(email),
    do: String.length(email) <= @max_length and format_error(email) == nil

  def valid?(_email), do: false

  defp format_error(email) do
    cond do
      # Check for control characters or null bytes
      String.match?(email, ~r/[\x00-\x1F\x7F]/) ->
        "must not contain control characters"

      # Validate format with regex
      not Regex.match?(@email_regex, email) ->
        "must be a valid email address"

      # Validate local part length (before @)
      String.split(email, "@") |> hd() |> String.length() > 64 ->
        "local part must be at most 64 characters"

      true ->
        nil
    end
  end

  @doc """
  Normalize an email address for storage or lookup: trim, then downcase.
  """
  def normalize(email) when is_binary(email) do
    email |> String.trim() |> String.downcase()
  end

  # Non-binary input (e.g. a forged list/map param) passes through
  # unchanged so cast/validate_required surfaces an ordinary invalid-type
  # changeset error instead of raising here.
  def normalize(email), do: email
end
