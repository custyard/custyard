defmodule Custyard.Contact do
  use Ecto.Schema
  import Ecto.Changeset

  schema "contacts" do
    field :email, :string
    field :name, :string
    field :is_admin, :boolean, default: false

    belongs_to :organization, Custyard.Organization
    has_many :conversations, Custyard.Conversation

    timestamps(type: :utc_datetime)
  end

  # Basic email validation: local-part@domain.tld
  # More restrictive than RFC 5322 but catches common issues:
  # - Exactly one @ sign
  # - No whitespace or control characters
  # - Reasonable length limits (local <= 64, domain <= 255, total <= 320)
  # - At least one dot in domain
  @email_regex ~r/^[a-zA-Z0-9.!#$%&'*+\/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$/

  @doc false
  def changeset(contact, attrs) do
    contact
    |> cast(attrs, [:email, :name, :is_admin, :organization_id])
    |> validate_required([:email, :organization_id])
    |> validate_length(:email, max: 320, message: "must be at most 320 characters")
    |> validate_email()
    |> unique_constraint([:email, :organization_id])
    |> foreign_key_constraint(:organization_id)
  end

  defp validate_email(changeset) do
    case get_change(changeset, :email) do
      nil ->
        changeset

      email ->
        cond do
          # Check for control characters or null bytes
          String.match?(email, ~r/[\x00-\x1F\x7F]/) ->
            add_error(changeset, :email, "must not contain control characters")

          # Validate format with regex
          not Regex.match?(@email_regex, email) ->
            add_error(changeset, :email, "must be a valid email address")

          # Validate local part length (before @)
          String.split(email, "@") |> hd() |> String.length() > 64 ->
            add_error(changeset, :email, "local part must be at most 64 characters")

          true ->
            changeset
        end
    end
  end
end
