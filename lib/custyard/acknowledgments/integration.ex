defmodule Custyard.Acknowledgments.Integration do
  @moduledoc "Tenant-owned acknowledgment subscription; the broker credential is encrypted."
  use Ecto.Schema
  import Ecto.Changeset

  schema "acknowledgment_integrations" do
    belongs_to :tenant, Custyard.Tenant
    field :source, :string
    field :url_ciphertext, :string, redact: true
    field :queue, :string
    field :enabled, :boolean, default: false
    timestamps(type: :utc_datetime)
  end

  def changeset(integration, attrs) do
    integration
    |> cast(attrs, [:tenant_id, :source, :url_ciphertext, :queue, :enabled])
    |> validate_required([:tenant_id, :source, :url_ciphertext, :queue])
    |> validate_length(:source, max: 255)
    |> validate_length(:queue, max: 200)
    |> unique_constraint(:tenant_id)
    |> foreign_key_constraint(:tenant_id)
  end
end
