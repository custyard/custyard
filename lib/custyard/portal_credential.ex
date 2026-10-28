defmodule Custyard.PortalCredential do
  @moduledoc "An independently revocable, hashed customer portal credential."
  use Ecto.Schema
  import Ecto.Changeset

  schema "portal_credentials" do
    field :token_hash, :string
    field :revoked_at, :utc_datetime
    belongs_to :tenant, Custyard.Tenant
    belongs_to :organization, Custyard.Organization
    belongs_to :contact, Custyard.Contact
    timestamps(type: :utc_datetime)
  end

  def changeset(credential, attrs) do
    credential
    |> cast(attrs, [:tenant_id, :organization_id, :contact_id, :token_hash])
    |> validate_required([:tenant_id, :organization_id, :token_hash])
    |> unique_constraint(:token_hash)
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:contact_id)
  end
end
