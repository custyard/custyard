defmodule Custyard.Label do
  use Ecto.Schema
  import Ecto.Changeset

  schema "labels" do
    field :name, :string
    field :normalized_name, :string
    belongs_to :tenant, Custyard.Tenant
    timestamps(type: :utc_datetime)
  end

  def changeset(label, attrs) do
    label
    |> cast(attrs, [:name, :tenant_id])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :tenant_id])
    |> validate_length(:name, min: 1, max: 40)
    |> normalize_name()
    |> unique_constraint([:tenant_id, :normalized_name])
    |> foreign_key_constraint(:tenant_id)
  end

  defp normalize_name(changeset) do
    case get_field(changeset, :name) do
      name when is_binary(name) -> put_change(changeset, :normalized_name, String.downcase(name))
      _ -> changeset
    end
  end
end
