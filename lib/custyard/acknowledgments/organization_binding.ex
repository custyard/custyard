defmodule Custyard.Acknowledgments.OrganizationBinding do
  @moduledoc "Explicit source-qualified organization attribution."
  use Ecto.Schema
  import Ecto.Changeset
  alias Custyard.Acknowledgments.Evidence

  schema "acknowledgment_organization_bindings" do
    field :source, :string
    field :source_organization_id, :string
    belongs_to :organization, Custyard.Organization
    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:source, :source_organization_id, :organization_id])
    |> validate_required([:source, :source_organization_id, :organization_id])
    |> validate_length(:source, max: 255)
    |> validate_length(:source_organization_id, max: 255)
    |> validate_change(:source, &validate_identity/2)
    |> validate_change(:source_organization_id, &validate_identity/2)
    |> validate_number(:organization_id, greater_than: 0)
    |> unique_constraint([:source, :source_organization_id])
    |> foreign_key_constraint(:organization_id)
  end

  defp validate_identity(field, value) do
    if Evidence.valid_identity?(value),
      do: [],
      else: [
        {field, "must be a nonblank identity of at most 255 bytes without control characters"}
      ]
  end
end
