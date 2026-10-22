defmodule Custyard.Contact do
  use Ecto.Schema
  import Ecto.Changeset

  @email_statuses [:valid, :bounced, :suppressed]

  schema "contacts" do
    field :email, :string
    field :name, :string
    field :is_admin, :boolean, default: false
    # Set from provider delivery events (Custyard.Email.DeliveryStatus):
    # a bounced or suppressed reply flags the address, a later delivery
    # clears it. Informational only; sends are never blocked.
    field :email_status, Ecto.Enum, values: @email_statuses, default: :valid
    field :email_status_at, :utc_datetime

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
    |> reset_email_status_on_change()
    |> unique_constraint([:email, :organization_id])
  end

  @doc "The email statuses a contact can carry."
  def email_statuses, do: @email_statuses

  # A bounce describes the old address, not the new one.
  defp reset_email_status_on_change(changeset) do
    if get_change(changeset, :email) do
      changeset
      |> put_change(:email_status, :valid)
      |> put_change(:email_status_at, nil)
    else
      changeset
    end
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
