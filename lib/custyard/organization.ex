defmodule Custyard.Organization do
  use Ecto.Schema
  import Ecto.Changeset

  schema "organizations" do
    field :name, :string
    field :domain, :string
    field :tier, Ecto.Enum, values: [:enterprise, :standard, :basic], default: :standard
    field :token, :string

    # Branding configuration for white-label portal
    field :logo_url, :string
    field :primary_color, :string
    field :secondary_color, :string

    # Custom domain for white-label portal (e.g., support.acme.com)
    field :custom_domain, :string

    has_many :contacts, Custyard.Contact
    has_many :conversations, Custyard.Conversation
    has_many :projects, Custyard.Project

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(organization, attrs) do
    organization
    |> cast(attrs, [:name, :domain, :tier, :token, :logo_url, :primary_color, :secondary_color, :custom_domain])
    |> maybe_generate_token()
    |> validate_required([:name, :token])
    |> validate_inclusion(:tier, [:enterprise, :standard, :basic])
    |> validate_format(:primary_color, ~r/^#[0-9A-Fa-f]{6}$/, message: "must be a valid hex color (e.g., #1a2b3c)")
    |> validate_format(:secondary_color, ~r/^#[0-9A-Fa-f]{6}$/, message: "must be a valid hex color (e.g., #1a2b3c)")
    |> unique_constraint(:token)
    |> unique_constraint(:custom_domain)
    |> validate_custom_domain()
  end

  defp validate_custom_domain(changeset) do
    case get_change(changeset, :custom_domain) do
      nil ->
        changeset

      domain when is_binary(domain) ->
        # Basic domain validation - must look like a hostname
        if Regex.match?(~r/^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$/i, domain) do
          changeset
        else
          add_error(changeset, :custom_domain, "must be a valid domain name")
        end
    end
  end

  @doc """
  Changeset for updating branding only.
  """
  def branding_changeset(organization, attrs) do
    organization
    |> cast(attrs, [:logo_url, :primary_color, :secondary_color])
    |> validate_format(:primary_color, ~r/^#[0-9A-Fa-f]{6}$/, message: "must be a valid hex color (e.g., #1a2b3c)")
    |> validate_format(:secondary_color, ~r/^#[0-9A-Fa-f]{6}$/, message: "must be a valid hex color (e.g., #1a2b3c)")
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
