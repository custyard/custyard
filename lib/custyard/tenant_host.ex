defmodule Custyard.TenantHost do
  @moduledoc "An explicit, globally unique hostname claimed by a tenant."
  use Ecto.Schema
  import Ecto.Changeset

  schema "tenant_hosts" do
    field :hostname, :string
    belongs_to :tenant, Custyard.Tenant
    timestamps(type: :utc_datetime)
  end

  def changeset(host, attrs) do
    host
    |> cast(attrs, [:hostname, :tenant_id])
    |> update_change(:hostname, &Custyard.Tenants.normalize_host/1)
    |> validate_required([:hostname, :tenant_id])
    |> validate_format(
      :hostname,
      ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\z/
    )
    |> validate_length(:hostname, max: 253)
    |> reject_installation_host()
    |> unique_constraint(:hostname)
    |> foreign_key_constraint(:tenant_id)
  end

  defp reject_installation_host(changeset) do
    if get_field(changeset, :hostname) ==
         Custyard.Tenants.normalize_host(Custyard.Tenants.app_host()),
       do: add_error(changeset, :hostname, "is reserved for the installation"),
       else: changeset
  end
end
