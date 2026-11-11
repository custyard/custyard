defmodule CustyardWeb.OriginValidator do
  @moduledoc "Allows LiveView origins only for the installation host and registered tenant hosts."
  import Ecto.Query
  alias Custyard.{Repo, TenantHost, Tenants}
  def check_origin?(uri), do: check_origin?(uri, [])

  def check_origin?(%URI{host: host}, _) when is_binary(host) do
    normalized = Tenants.normalize_host(host)

    normalized == Tenants.normalize_host(Tenants.app_host()) or
      not is_nil(Tenants.resolve_host(normalized))
  end

  def check_origin?(_, _), do: false
  def check_origin(value) when is_binary(value), do: check_origin?(URI.parse(value))
  def check_origin(_), do: false

  def list_valid_origins do
    [Tenants.app_host() | Repo.all(from h in TenantHost, select: h.hostname)]
    |> Enum.uniq()
    |> Enum.map(&("//" <> &1))
  end
end
