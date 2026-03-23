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

  @doc false
  def changeset(contact, attrs) do
    contact
    |> cast(attrs, [:email, :name, :is_admin, :organization_id])
    |> validate_required([:email, :organization_id])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email address")
    |> unique_constraint(:email)
    |> foreign_key_constraint(:organization_id)
  end
end
