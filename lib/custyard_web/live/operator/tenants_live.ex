defmodule CustyardWeb.Operator.TenantsLive do
  use CustyardWeb, :live_view
  alias Custyard.{OperatorAccount, Tenants, Tenant}

  def mount(params, _, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Tenants")
     |> assign(:tenant_host?, not is_nil(socket.assigns[:host_tenant_id]))
     |> assign(:switch_required?, params["switch"] == "required")
     |> load(), layout: {CustyardWeb.Layouts, :operator}}
  end

  def handle_event("create", %{"tenant" => attrs}, socket) do
    if OperatorAccount.super_admin?(socket.assigns.current_operator) and
         not socket.assigns.tenant_host? do
      case Tenants.create_tenant_for_operator(
             socket.assigns.current_operator,
             Map.take(attrs, ~w(name slug custom_domain))
           ) do
        {:ok, _} ->
          {:noreply,
           socket
           |> load()
           |> put_flash(:info, "Tenant created. Select it to configure email and invite staff.")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset))}

        {:error, :unauthorized} ->
          {:noreply, put_flash(socket, :error, "Instance administrator required")}
      end
    else
      message =
        if socket.assigns.tenant_host?,
          do: "Open the instance console to create a tenant",
          else: "Instance administrator required"

      {:noreply, put_flash(socket, :error, message)}
    end
  end

  defp load(socket),
    do:
      socket
      |> assign(:tenants, Tenants.list_tenants())
      |> assign(:form, to_form(Tenant.changeset(%Tenant{}, %{})))

  def render(assigns) do
    ~H"""
    <div class="max-w-3xl mx-auto p-6 space-y-6">
      <.header>
        Tenants<:subtitle>
          Each tenant has its own staff, branding, support addresses and customer organizations.
        </:subtitle>
      </.header>
      <div :if={@tenant_host?} role="status" class="rounded border p-4 space-y-2">
        <p>
          Switch tenants on the instance console at {Tenants.app_host()}. Sign in there if needed,
          then select the tenant you want to manage.
        </p>
        <.link href={CustyardWeb.Endpoint.url() <> ~p"/operator/tenants"} class="text-indigo-600">
          Open instance console
        </.link>
      </div>
      <p :if={@switch_required? and not @tenant_host?} role="status">
        Select a tenant here to finish switching workspaces.
      </p>
      <div
        :for={tenant <- @tenants}
        :if={not @tenant_host?}
        class="rounded border p-4 flex justify-between gap-4"
      >
        <div>
          <strong>{tenant.name}</strong><p class="text-sm">{Tenants.host(tenant)}</p>
        </div>
        <.link
          href={~p"/operator/tenants/#{tenant.id}/select"}
          method="post"
          class="text-indigo-600 dark:text-indigo-400"
        >Select tenant</.link>
      </div>
      <.simple_form :if={not @tenant_host?} for={@form} id="tenant-create" phx-submit="create">
        <.input field={@form[:name]} label="Tenant name" required />
        <.input field={@form[:slug]} label="Subdomain" required />
        <p class="text-sm text-gray-500">
          A subdomain of {Tenants.app_host()}. Configure DNS and TLS at your hosting provider.
        </p>
        <.input field={@form[:custom_domain]} label="Custom domain (optional)" />
        <:actions><.button>Create tenant</.button></:actions>
      </.simple_form>
    </div>
    """
  end
end
