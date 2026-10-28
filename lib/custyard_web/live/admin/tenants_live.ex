defmodule CustyardWeb.Admin.TenantsLive do
  use CustyardWeb, :live_view
  alias Custyard.{Tenant, Tenants}
  def mount(_, _, socket), do: {:ok, socket |> assign(:page_title, "Instance admin") |> load()}

  def handle_params(params, _, socket) do
    tenant =
      case params["id"] do
        nil -> nil
        id -> Tenants.get_tenant!(id)
      end

    {:noreply, assign(socket, :tenant, tenant && Custyard.Repo.preload(tenant, :hosts))}
  end

  def handle_event("create", %{"tenant" => attrs}, socket) do
    case Tenants.create_tenant_for_admin(socket.assigns.current_instance_admin, attrs) do
      {:ok, tenant} ->
        {:noreply,
         socket |> load() |> push_navigate(to: ~p"/admin/tenants/#{tenant.id}/settings")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset, as: :tenant))}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not create tenant")}
    end
  end

  def handle_event("status", %{"status" => status}, socket) do
    case Tenants.set_status(
           socket.assigns.current_instance_admin,
           socket.assigns.tenant.id,
           status
         ) do
      {:ok, tenant} ->
        {:noreply, socket |> assign(:tenant, Custyard.Repo.preload(tenant, :hosts)) |> load()}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not change status")}
    end
  end

  def handle_event("staff", %{"staff" => attrs}, socket) do
    case Tenants.provision_staff(
           socket.assigns.current_instance_admin,
           socket.assigns.tenant.id,
           attrs
         ) do
      {:ok, _} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           "Staff account created. Request a login link on the tenant host."
         )}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, inspect(changeset.errors))}
    end
  end

  def handle_event("host", %{"hostname" => hostname}, socket) do
    case Tenants.add_host_for_admin(
           socket.assigns.current_instance_admin,
           socket.assigns.tenant.id,
           hostname
         ) do
      {:ok, _} ->
        {:noreply,
         assign(
           socket,
           :tenant,
           Custyard.Repo.preload(socket.assigns.tenant, :hosts, force: true)
         )}

      _ ->
        {:noreply, put_flash(socket, :error, "Hostname is invalid or already claimed")}
    end
  end

  def handle_event("remove_host", %{"id" => id}, socket) do
    case Tenants.remove_host(
           socket.assigns.current_instance_admin,
           socket.assigns.tenant.id,
           String.to_integer(id)
         ) do
      {:ok, _} ->
        {:noreply,
         assign(
           socket,
           :tenant,
           Custyard.Repo.preload(socket.assigns.tenant, :hosts, force: true)
         )}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not remove hostname")}
    end
  end

  defp load(socket),
    do:
      socket
      |> assign(:tenants, Tenants.list_tenants())
      |> assign(:form, to_form(Tenant.changeset(%Tenant{}, %{})))

  def render(assigns) do
    ~H"""
    <.header>
      Tenants<:subtitle>Manage workspace hosting, lifecycle and staff provisioning.</:subtitle>
    </.header>
    <ul class="my-6 space-y-3">
      <li :for={tenant <- @tenants}>
        <.link navigate={~p"/admin/tenants/#{tenant.id}/settings"}>{tenant.name} · {tenant.status}</.link>
        <.link
          :if={Tenants.host(tenant)}
          href={Tenants.url(tenant) <> "/app/login"}
          class="ml-4 text-sm"
        >Staff sign in to {tenant.name}</.link>
      </li>
    </ul>
    <section :if={@tenant} class="space-y-4 border rounded p-4 mb-8">
      <h2 class="font-bold">{@tenant.name}</h2>
      <p>Status: {@tenant.status}</p>
      <.button
        phx-click="status"
        phx-value-status={if @tenant.status == "active", do: "suspended", else: "active"}
      >{if @tenant.status == "active", do: "Suspend workspace", else: "Resume workspace"}</.button>
      <h3 class="font-semibold">Registered hostnames</h3>
      <p :for={host <- @tenant.hosts}>
        {host.hostname} <button phx-click="remove_host" phx-value-id={host.id}>Remove</button>
      </p>
      <form phx-submit="host">
        <input name="hostname" aria-label="Hostname" required /><.button>Add hostname</.button>
      </form>
      <h3 class="font-semibold">Provision staff</h3>
      <form phx-submit="staff" class="flex gap-2">
        <input name="staff[email]" type="email" aria-label="Staff email" required /><select
          name="staff[role]"
          aria-label="Staff role"
        ><option value="admin">Administrator</option><option value="agent">Agent</option></select><.button>Add staff</.button>
      </form>
      <p>Sign in to the tenant's staff account to access customer data.</p>
    </section>
    <.simple_form for={@form} id="tenant-create" phx-submit="create">
      <.input field={@form[:name]} label="Tenant name" required />
      <.input field={@form[:slug]} label="Tenant identifier" required />
      <label>Hostname<input name="tenant[hostname]" required class="block" /></label>
      <p>
        Register a workspace subdomain or custom domain with DNS and TLS configured. {Tenants.app_host()} is reserved for this installation.
      </p>
      <:actions><.button>Create tenant</.button></:actions>
    </.simple_form>
    """
  end
end
