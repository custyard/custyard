defmodule Custyard.Team do
  @moduledoc """
  Represents a team of operators scoped to an organization.

  Teams group operators and provide organizational context for
  role-based access control. Each team belongs to one organization.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "teams" do
    field :name, :string

    belongs_to :organization, Custyard.Organization
    has_many :operator_accounts, Custyard.OperatorAccount

    timestamps(type: :utc_datetime)
  end

  @doc false
  def changeset(team, attrs) do
    team
    |> cast(attrs, [:name, :organization_id])
    |> validate_required([:name])
    |> unique_constraint([:organization_id, :name])
    |> foreign_key_constraint(:organization_id)
  end
end
