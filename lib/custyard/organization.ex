defmodule Custyard.Organization do
  use Ecto.Schema
  import Ecto.Changeset

  schema "organizations" do
    field :name, :string
    field :domain, :string
    field :tier, Ecto.Enum, values: [:enterprise, :standard, :basic], default: :standard
    field :token, :string

    has_many :contacts, Custyard.Contact
    has_many :conversations, Custyard.Conversation

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(organization, attrs) do
    organization
    |> cast(attrs, [:name, :domain, :tier, :token])
    |> maybe_generate_token()
    |> validate_required([:name, :token])
    |> validate_inclusion(:tier, [:enterprise, :standard, :basic])
    |> unique_constraint(:token)
  end

  defp maybe_generate_token(changeset) do
    case get_field(changeset, :token) do
      nil -> put_change(changeset, :token, generate_token())
      _ -> changeset
    end
  end

  defp generate_token do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
