defmodule Custyard.InboundRoute do
  @moduledoc """
  Represents a Lettermint inbound route that maps to an organization and
  optionally a project. Each route has a unique callback_token embedded
  in its webhook URL for routing incoming messages.

  Route types:
  - `:general` — org-wide catch-all route
  - `:project` — project-specific route (sets project_id on conversations)
  - `:disambiguation` — handles ambiguous sender resolution via DM
  """
  use Ecto.Schema
  import Ecto.Changeset

  @route_types [:general, :project, :disambiguation]

  schema "inbound_routes" do
    field :lettermint_route_id, :string
    field :callback_token, :string
    field :route_type, Ecto.Enum, values: @route_types, default: :general

    belongs_to :organization, Custyard.Organization
    belongs_to :project, Custyard.Project
    has_many :webhooks, Custyard.InboundRouteWebhook

    timestamps(type: :utc_datetime)
  end

  def route_types, do: @route_types

  @doc false
  def changeset(route, attrs) do
    route
    |> cast(attrs, [
      :lettermint_route_id,
      :callback_token,
      :route_type,
      :organization_id,
      :project_id
    ])
    |> maybe_generate_callback_token()
    |> validate_required([:callback_token, :route_type, :organization_id])
    |> validate_inclusion(:route_type, @route_types)
    |> unique_constraint(:callback_token)
    |> foreign_key_constraint(:organization_id)
    |> foreign_key_constraint(:project_id)
    |> validate_project_route()
  end

  defp validate_project_route(changeset) do
    route_type = get_field(changeset, :route_type)
    project_id = get_field(changeset, :project_id)

    if route_type == :project and is_nil(project_id) do
      add_error(changeset, :project_id, "is required for project routes")
    else
      changeset
    end
  end

  defp maybe_generate_callback_token(changeset) do
    case get_field(changeset, :callback_token) do
      nil -> put_change(changeset, :callback_token, generate_token())
      _ -> changeset
    end
  end

  defp generate_token do
    :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false)
  end
end
