defmodule Custyard.Tenant do
  use Ecto.Schema
  import Ecto.Changeset

  schema "tenants" do
    field :name, :string
    field :slug, :string
    field :status, :string, default: "active"
    field :outbound_paused, :boolean, default: false
    has_many :hosts, Custyard.TenantHost
    field :logo_url, :string
    field :primary_color, :string
    field :secondary_color, :string
    has_many :organizations, Custyard.Organization
    has_many :staff_accounts, Custyard.StaffAccount
    has_many :inbound_routes, Custyard.InboundRoute
    has_many :inbound_channels, Custyard.InboundChannel
    timestamps(type: :utc_datetime)
  end

  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, [:name, :slug, :status, :logo_url, :primary_color, :secondary_color])
    |> update_change(:slug, &normalize/1)
    |> update_change(:status, &normalize/1)
    |> validate_required([:name, :slug])
    |> validate_length(:name, max: 200)
    |> validate_format(:slug, ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/)
    |> validate_exclusion(:slug, ~w(www api staff dev assets mail support),
      message: "is reserved"
    )
    |> validate_inclusion(:status, ~w(active suspended))
    |> validate_format(:primary_color, ~r/\A#[0-9a-fA-F]{6}\z/)
    |> validate_format(:secondary_color, ~r/\A#[0-9a-fA-F]{6}\z/)
    |> validate_change(:logo_url, fn :logo_url, value ->
      case Custyard.UploadPath.validate(value) do
        :ok -> []
        {:error, error} -> [logo_url: error]
      end
    end)
    |> unique_constraint(:slug)
  end

  defp normalize(value) when is_binary(value), do: value |> String.trim() |> String.downcase()
end
