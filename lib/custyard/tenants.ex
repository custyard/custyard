defmodule Custyard.Tenants do
  @moduledoc "Tenant ownership, host resolution and instance administration."
  import Ecto.Query
  alias Custyard.{OperatorAccount, Repo, Tenant}

  def default_tenant, do: Repo.get!(Tenant, 1)
  def get_tenant(id), do: Repo.get(Tenant, id)
  def get_tenant!(id), do: Repo.get!(Tenant, id)
  def list_tenants, do: Repo.all(from t in Tenant, order_by: t.name)

  def create_tenant(attrs), do: %Tenant{} |> change_tenant(attrs) |> Repo.insert()

  def update_tenant(%Tenant{} = tenant, attrs),
    do: tenant |> change_tenant(attrs) |> Repo.update()

  def change_tenant(tenant, attrs \\ %{}) do
    tenant |> Tenant.changeset(attrs) |> validate_hosts()
  end

  defp validate_hosts(changeset) do
    changeset |> validate_default_slug() |> validate_custom_host() |> validate_subdomain_host()
  end

  defp validate_default_slug(changeset) do
    import Ecto.Changeset

    case {changeset.data.id, get_field(changeset, :slug), changed?(changeset, :slug)} do
      {1, _, true} -> add_error(changeset, :slug, "cannot change the default tenant subdomain")
      {nil, "default", _} -> add_error(changeset, :slug, "is reserved for the default tenant")
      _ -> changeset
    end
  end

  defp validate_custom_host(changeset) do
    import Ecto.Changeset

    case get_field(changeset, :custom_domain) do
      domain when is_binary(domain) ->
        cond do
          domain == app_host() or String.ends_with?(domain, "." <> app_host()) ->
            add_error(
              changeset,
              :custom_domain,
              "use the subdomain field for an instance hostname"
            )

          customer_host?(domain) ->
            add_error(changeset, :custom_domain, "is already used by a customer portal")

          true ->
            changeset
        end

      _ ->
        changeset
    end
  end

  defp validate_subdomain_host(changeset) do
    import Ecto.Changeset

    case get_field(changeset, :slug) do
      slug when is_binary(slug) ->
        if customer_host?(slug <> "." <> app_host()),
          do: add_error(changeset, :slug, "hostname is already used by a customer portal"),
          else: changeset

      _ ->
        changeset
    end
  end

  defp customer_host?(host),
    do: Repo.exists?(from o in Custyard.Organization, where: o.custom_domain == ^host)

  def can_manage?(%OperatorAccount{role: "super_admin"}, %Tenant{}), do: true
  def can_manage?(%OperatorAccount{role: "admin", tenant_id: id}, %Tenant{id: id}), do: true
  def can_manage?(_, _), do: false

  def create_tenant_for_operator(%OperatorAccount{} = operator, attrs) do
    Repo.transaction(fn ->
      current = Custyard.OperatorAccess.lock_current(operator)

      unless current && current.role == "super_admin" &&
               OperatorAccount.session_claim_matches?(current, operator.session_claim),
             do: Repo.rollback(:unauthorized)

      case create_tenant(attrs) do
        {:ok, tenant} -> tenant
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def update_tenant_for_operator(%OperatorAccount{} = operator, tenant_id, attrs) do
    Repo.transaction(fn ->
      lock_manager!(operator, tenant_id)

      case update_tenant(get_tenant!(tenant_id), attrs) do
        {:ok, tenant} -> tenant
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def invite_staff(%OperatorAccount{} = operator, tenant_id, attrs) do
    Repo.transaction(fn ->
      lock_manager!(operator, tenant_id)

      changeset =
        OperatorAccount.changeset(%OperatorAccount{}, %{
          email: Map.get(attrs, "email", attrs[:email]),
          role: Map.get(attrs, "role", attrs[:role]),
          tenant_id: tenant_id
        })
        |> Ecto.Changeset.validate_required(:role)
        |> Ecto.Changeset.validate_inclusion(:role, ["admin", "agent"],
          message: "must be administrator or agent"
        )

      case Repo.insert(changeset) do
        {:ok, staff} -> staff
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def remove_staff(%OperatorAccount{} = operator, tenant_id, staff_id) do
    Repo.transaction(fn ->
      current = lock_manager!(operator, tenant_id)
      staff = lock_tenant_staff!(tenant_id, staff_id)
      if current.id == staff.id, do: Repo.rollback(:self_removal)
      protect_last_admin!(staff, tenant_id)

      case Custyard.OperatorAccounts.remove_operator(staff.email,
             via: "operator",
             actor_operator_id: current.id
           ) do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def legacy_staff(tenant_id) do
    Repo.all(
      from o in OperatorAccount,
        join: organization in assoc(o, :organization),
        where: is_nil(o.tenant_id) and organization.tenant_id == ^tenant_id,
        where: o.role in ["admin", "agent"],
        order_by: o.email,
        preload: [:organization]
    )
  end

  @doc "Explicit instance-administrator conversion from one customer to the whole tenant."
  def grant_tenant_access(%OperatorAccount{} = operator, tenant_id, staff_id) do
    Repo.transaction(fn ->
      current = lock_manager!(operator, tenant_id)
      unless current.role == "super_admin", do: Repo.rollback(:unauthorized)
      staff = Custyard.OperatorAccess.lock_current(%OperatorAccount{id: staff_id})
      unless legacy_member?(staff, tenant_id), do: Repo.rollback(:not_found)
      organization_id = staff.organization_id

      updated =
        staff
        |> OperatorAccount.role_changeset(%{tenant_id: tenant_id, organization_id: nil})
        |> Ecto.Changeset.change(session_claim: OperatorAccount.generate_session_claim())
        |> Repo.update!()

      Custyard.AuditEvent.create(%{
        event_type: :operator_tenant_access_granted,
        source: "operator",
        payload: %{
          operator_id: staff.id,
          actor_operator_id: current.id,
          tenant_id: tenant_id,
          previous_organization_id: organization_id,
          role: staff.role
        }
      })

      updated
    end)
  end

  defp legacy_member?(
         %OperatorAccount{tenant_id: nil, organization_id: id, role: role},
         tenant_id
       )
       when is_integer(id) and role in ["admin", "agent"] do
    Repo.exists?(
      from o in Custyard.Organization, where: o.id == ^id and o.tenant_id == ^tenant_id
    )
  end

  defp legacy_member?(_, _), do: false

  defp lock_manager!(operator, tenant_id) do
    current = Custyard.OperatorAccess.lock_current(operator)
    tenant = get_tenant(tenant_id)

    unless current && tenant && can_manage?(current, tenant) &&
             OperatorAccount.session_claim_matches?(current, operator.session_claim),
           do: Repo.rollback(:unauthorized)

    current
  end

  defp lock_tenant_staff!(tenant_id, staff_id) do
    query =
      from o in OperatorAccount,
        where: o.id == ^staff_id and o.tenant_id == ^tenant_id and o.role in ["admin", "agent"],
        update: [set: [updated_at: o.updated_at]]

    case Repo.update_all(query, []) do
      {1, _} -> Repo.get!(OperatorAccount, staff_id)
      _ -> Repo.rollback(:not_found)
    end
  end

  defp protect_last_admin!(%OperatorAccount{role: "admin", id: id}, tenant_id) do
    unless Repo.exists?(
             from o in OperatorAccount,
               where: o.tenant_id == ^tenant_id and o.role == "admin" and o.id != ^id
           ),
           do: Repo.rollback(:last_admin)
  end

  defp protect_last_admin!(_, _), do: :ok

  def for_operator(%OperatorAccount{tenant_id: id}) when is_integer(id), do: get_tenant(id)

  def for_operator(%OperatorAccount{organization_id: id}) when is_integer(id) do
    case Repo.get(Custyard.Organization, id) do
      %{tenant_id: tenant_id} -> get_tenant(tenant_id)
      _ -> default_tenant()
    end
  end

  def for_operator(_), do: default_tenant()

  def operator_on_host?(%OperatorAccount{role: "super_admin"}, _), do: true
  def operator_on_host?(_, nil), do: true
  def operator_on_host?(%OperatorAccount{tenant_id: id}, id) when is_integer(id), do: true

  def operator_on_host?(%OperatorAccount{tenant_id: nil, organization_id: org_id}, id)
      when is_integer(org_id) do
    case Repo.get(Custyard.Organization, org_id) do
      %{tenant_id: ^id} -> true
      _ -> false
    end
  end

  def operator_on_host?(_, _), do: false

  def host(%Tenant{custom_domain: domain}) when is_binary(domain), do: domain
  def host(%Tenant{slug: "default"}), do: app_host()
  def host(%Tenant{slug: slug}), do: slug <> "." <> app_host()

  def url(%Tenant{} = tenant) do
    CustyardWeb.Endpoint.url() |> URI.parse() |> Map.put(:host, host(tenant)) |> URI.to_string()
  end

  def portal_url(%{tenant_id: 1, token: token}), do: CustyardWeb.Endpoint.url() <> "/p/" <> token
  def portal_url(%{tenant_id: id, token: token}), do: url(get_tenant!(id)) <> "/p/" <> token

  def app_host do
    get_in(Application.get_env(:custyard, CustyardWeb.Endpoint, []), [:url, :host]) || "localhost"
  end

  def resolve_host(host) when is_binary(host) do
    host = host |> String.downcase() |> String.trim_trailing(".")

    case Repo.get_by(Tenant, custom_domain: host) do
      %Tenant{} = tenant -> tenant
      nil -> resolve_subdomain(host)
    end
  end

  defp resolve_subdomain(host) do
    suffix = "." <> app_host()

    if String.ends_with?(host, suffix) do
      slug = String.replace_suffix(host, suffix, "")
      if not String.contains?(slug, "."), do: Repo.get_by(Tenant, slug: slug)
    end
  end

  def branding(%Tenant{} = tenant) do
    instance = Custyard.Settings.get_branding()

    %{
      name: tenant.name,
      logo_url: tenant.logo_url,
      primary_color: tenant.primary_color || instance.primary_color
    }
  end
end
