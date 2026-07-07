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

  @doc """
  Changeset for creating a new contact.
  """
  def changeset(contact, attrs) do
    contact
    |> cast(attrs, [:email, :name, :is_admin, :organization_id])
    |> validate_required([:email, :organization_id])
    |> validate_organization_immutable()
    |> validate_length(:email, max: 320, message: "must be at most 320 characters")
    |> validate_email()
    |> unique_constraint([:email, :organization_id])
    |> foreign_key_constraint(:organization_id)
  end

  @doc """
  Changeset for updating an existing contact.
  Does not allow changing organization_id to prevent orphaning conversations.
  """
  def update_changeset(contact, attrs) do
    contact
    |> cast(attrs, [:email, :name, :is_admin])
    |> validate_length(:email, max: 320, message: "must be at most 320 characters")
    |> validate_email()
    |> unique_constraint([:email, :organization_id])
  end

  # Prevent changing organization_id on existing contacts
  defp validate_organization_immutable(changeset) do
    # Only validate on updates (when data has an id)
    if changeset.data.id && get_change(changeset, :organization_id) do
      add_error(
        changeset,
        :organization_id,
        "cannot be changed after contact is created"
      )
    else
      changeset
    end
  end

  # Email validation rules are shared with other email-bearing schemas
  # (e.g. Prospect) via Custyard.EmailAddress; behavior is identical to the
  # rules that historically lived here.
  defp validate_email(changeset) do
    Custyard.EmailAddress.validate_email(changeset, :email)
  end
end
