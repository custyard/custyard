defmodule Custyard.Acknowledgments.Acknowledgment do
  @moduledoc "Immutable historical evidence. Delivery metadata belongs to the transport."
  use Ecto.Schema
  import Ecto.Changeset

  schema "acknowledgments" do
    field :schema_version, :integer
    field :source, :string
    field :submission_id, :string
    field :source_organization_id, :string
    field :actor_id, :string
    field :actor_role, :string
    field :actor_type, :string
    field :statement_key, :string
    field :statement_version, :string
    field :statement_text, :string
    field :statement_hash, :string
    # Keep the exact serialized source time as evidence.
    field :acknowledged_at, :string
    field :received_at, :utc_datetime_usec
    belongs_to :organization, Custyard.Organization
  end

  @fields ~w(schema_version source submission_id source_organization_id actor_id actor_role actor_type statement_key statement_version statement_text statement_hash acknowledged_at received_at organization_id)a
  def changeset(record, attrs) do
    record
    |> cast(attrs, @fields, empty_values: [])
    |> validate_required(@fields)
    |> unique_constraint([:source, :submission_id])
    |> foreign_key_constraint(:organization_id)
  end
end
