defmodule Custyard.Tenants do
  @moduledoc "Explicit tenant ownership, host registry and installation lifecycle."
  import Ecto.Query

  alias Custyard.{
    Auth.Account,
    AuditEvent,
    InstanceAdmin,
    Message,
    StaffAccount,
    Repo,
    Tenant,
    TenantHost
  }

  alias Custyard.Acknowledgments.Subscriptions

  def get_tenant(id), do: Repo.get(Tenant, id)
  def get_tenant!(id), do: Repo.get!(Tenant, id)
  def list_tenants, do: Repo.all(from t in Tenant, order_by: t.name, preload: [:hosts])
  def create_tenant(attrs), do: %Tenant{} |> change_tenant(attrs) |> Repo.insert()

  def update_tenant(%Tenant{} = tenant, attrs),
    do: tenant |> change_tenant(attrs) |> Repo.update()

  def change_tenant(tenant, attrs \\ %{}), do: Tenant.changeset(tenant, attrs)

  def create_tenant_for_admin(%InstanceAdmin{} = admin, attrs) do
    Repo.transaction(fn ->
      lock_admin!(admin)
      attrs = Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
      tenant_attrs = Map.take(attrs, ~w(name slug))

      tenant =
        case create_tenant(tenant_attrs) do
          {:ok, tenant} -> tenant
          {:error, changeset} -> Repo.rollback(changeset)
        end

      hostname = Map.get(attrs, "hostname", Map.get(attrs, :hostname))

      case add_host(tenant.id, hostname) do
        {:ok, _} -> tenant
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def set_status(%InstanceAdmin{} = admin, tenant_id, status)
      when status in ~w(active suspended) do
    Repo.transaction(fn ->
      lock_admin!(admin)
      tenant = get_tenant!(tenant_id)
      updated = tenant |> Ecto.Changeset.change(status: status) |> Repo.update!()

      case AuditEvent.create(%{
             tenant_id: tenant_id,
             event_type: :tenant_status_changed,
             source: "instance_admin",
             payload: %{instance_admin_id: admin.id, status: status}
           }) do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      updated
    end)
    |> tap(fn
      {:ok, _} ->
        Subscriptions.refresh(tenant_id)

        Phoenix.PubSub.broadcast(
          Custyard.PubSub,
          "tenant_lifecycle",
          {:tenant_status_changed, tenant_id}
        )

      _ ->
        :ok
    end)
  end

  def set_status(_, _, _), do: {:error, :invalid_status}

  def can_manage?(%StaffAccount{role: "admin", tenant_id: id}, %Tenant{
        id: id,
        status: "active"
      }),
      do: true

  def can_manage?(_, _), do: false

  def update_tenant_for_staff(%StaffAccount{} = staff, tenant_id, attrs) do
    Repo.transaction(fn ->
      lock_manager!(staff, tenant_id)

      allowed =
        Map.take(attrs, [
          :name,
          :logo_url,
          :primary_color,
          :secondary_color,
          "name",
          "logo_url",
          "primary_color",
          "secondary_color"
        ])

      case update_tenant(get_tenant!(tenant_id), allowed) do
        {:ok, tenant} -> tenant
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def invite_staff(%StaffAccount{} = staff, tenant_id, attrs) do
    Repo.transaction(fn ->
      lock_manager!(staff, tenant_id)
      insert_staff!(tenant_id, attrs)
    end)
  end

  def provision_staff(%InstanceAdmin{} = admin, tenant_id, attrs) do
    Repo.transaction(fn ->
      lock_admin!(admin)
      get_tenant!(tenant_id)
      insert_staff!(tenant_id, attrs)
    end)
  end

  defp insert_staff!(tenant_id, attrs) do
    changeset =
      StaffAccount.changeset(%StaffAccount{}, %{
        email: Map.get(attrs, "email", attrs[:email]),
        role: Map.get(attrs, "role", Map.get(attrs, :role, "admin")),
        tenant_id: tenant_id
      })

    case Repo.insert(changeset) do
      {:ok, staff} -> staff
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  def remove_staff(%StaffAccount{} = staff, tenant_id, staff_id) do
    Repo.transaction(fn ->
      current = lock_manager!(staff, tenant_id)
      if current.id == staff_id, do: Repo.rollback(:self_removal)

      target =
        Repo.get_by(StaffAccount, id: staff_id, tenant_id: tenant_id) ||
          Repo.rollback(:not_found)

      if target.role == "admin" and
           not Repo.exists?(
             from a in StaffAccount,
               where: a.tenant_id == ^tenant_id and a.role == "admin" and a.id != ^staff_id
           ),
         do: Repo.rollback(:last_admin)

      deleted_message_ids = detach_message_actor(tenant_id, target.id, :deleted_by_staff_id)

      forwarded_message_ids =
        detach_message_actor(tenant_id, target.id, :forwarded_by_staff_id)

      deleted = Repo.delete!(target)

      case AuditEvent.create(%{
             tenant_id: tenant_id,
             event_type: :staff_removed,
             source: "tenant:#{tenant_id}:staff:#{current.id}",
             payload: %{
               staff_id: target.id,
               role: target.role,
               deleted_message_ids: deleted_message_ids,
               forwarded_message_ids: forwarded_message_ids
             }
           }) do
        {:ok, _} -> deleted
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp detach_message_actor(tenant_id, staff_id, actor_field) do
    query =
      from m in Message,
        where: m.tenant_id == ^tenant_id and field(m, ^actor_field) == ^staff_id,
        order_by: m.id

    ids = Repo.all(from m in query, select: m.id)
    Repo.update_all(exclude(query, :order_by), set: [{actor_field, nil}])
    ids
  end

  defp lock_manager!(staff, tenant_id) do
    current = Account.lock_current(staff)

    unless current && can_manage?(current, get_tenant(tenant_id)) &&
             Account.session_claim_matches?(current, staff.session_claim),
           do: Repo.rollback(:unauthorized)

    current
  end

  defp lock_admin!(admin) do
    current = Account.lock_current(admin)

    unless current && Account.session_claim_matches?(current, admin.session_claim),
      do: Repo.rollback(:unauthorized)

    current
  end

  def for_staff(%StaffAccount{tenant_id: id}) when is_integer(id), do: get_tenant(id)
  def for_staff(_), do: nil
  def staff_on_host?(%StaffAccount{tenant_id: id}, id) when is_integer(id), do: active?(id)
  def staff_on_host?(_, _), do: false
  def active?(id), do: match?(%Tenant{status: "active"}, get_tenant(id))

  def add_host(tenant_id, hostname),
    do:
      %TenantHost{}
      |> TenantHost.changeset(%{tenant_id: tenant_id, hostname: hostname})
      |> Repo.insert()

  def remove_host(%InstanceAdmin{} = admin, tenant_id, host_id) do
    Repo.transaction(fn ->
      lock_admin!(admin)

      host =
        Repo.get_by(TenantHost, tenant_id: tenant_id, id: host_id) || Repo.rollback(:not_found)

      Repo.delete!(host)
    end)
  end

  def add_host_for_admin(%InstanceAdmin{} = admin, tenant_id, hostname) do
    Repo.transaction(fn ->
      lock_admin!(admin)

      case add_host(tenant_id, hostname) do
        {:ok, host} -> host
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def normalize_host(host) when is_binary(host),
    do: host |> String.trim() |> String.downcase() |> String.trim_trailing(".")

  def resolve_host(host) when is_binary(host) do
    hostname = normalize_host(host)

    if hostname != normalize_host(app_host()) do
      Repo.one(
        from h in TenantHost,
          join: t in assoc(h, :tenant),
          where: h.hostname == ^hostname,
          select: t
      )
    end
  end

  def resolve_host(_), do: nil

  def host(%Tenant{id: id}) do
    installation_host = normalize_host(app_host())

    Repo.one(
      from h in TenantHost,
        where: h.tenant_id == ^id and h.hostname != ^installation_host,
        order_by: h.id,
        limit: 1,
        select: h.hostname
    )
  end

  def url(%Tenant{} = tenant) do
    case host(tenant) do
      nil -> raise ArgumentError, "tenant has no registered hostname"
      host -> CustyardWeb.Endpoint.url() |> URI.parse() |> Map.put(:host, host) |> URI.to_string()
    end
  end

  def app_host,
    do:
      get_in(Application.get_env(:custyard, CustyardWeb.Endpoint, []), [:url, :host]) ||
        "localhost"

  def branding(%Tenant{} = tenant) do
    %{
      name: tenant.name,
      logo_url: tenant.logo_url,
      primary_color: tenant.primary_color || "#4f46e5"
    }
  end
end
