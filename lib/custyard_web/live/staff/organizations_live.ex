defmodule CustyardWeb.Staff.OrganizationsLive do
  use CustyardWeb, :live_view
  alias Custyard.{Authorization, Organizations}

  def mount(_, _, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Customers")
     |> assign(:editing_org, nil)
     |> assign(:show_form, false)
     |> assign(
       :form,
       to_form(%{"name" => "", "domain" => "", "tier" => "standard"}, as: :customer)
     )
     |> load(), layout: {CustyardWeb.Layouts, :staff}}
  end

  def handle_event("show_form", _, socket),
    do: {:noreply, socket |> assign(:show_form, true) |> assign(:editing_org, nil)}

  def handle_event("hide_form", _, socket), do: {:noreply, assign(socket, :show_form, false)}

  def handle_event("edit_org", %{"id" => id}, socket) do
    case Organizations.get(socket.assigns.current_scope, id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Customer unavailable")}

      org ->
        {:noreply,
         socket
         |> assign(:editing_org, org)
         |> assign(:show_form, true)
         |> assign(
           :form,
           to_form(
             %{"name" => org.name, "domain" => org.domain || "", "tier" => to_string(org.tier)},
             as: :customer
           )
         )}
    end
  end

  def handle_event("save_org", %{"customer" => attrs}, socket) do
    staff = socket.assigns.current_staff
    org = socket.assigns.editing_org

    permitted =
      if org,
        do: Authorization.can_manage_organization?(staff, org.id),
        else: Authorization.can_create_organization?(staff)

    if permitted do
      attrs =
        Map.take(attrs, ~w(name domain tier))
        |> Map.put("tenant_id", socket.assigns.current_tenant.id)

      result =
        if org,
          do:
            Organizations.update(
              socket.assigns.current_scope,
              org,
              Map.delete(attrs, "tenant_id")
            ),
          else: Organizations.create(socket.assigns.current_scope, attrs)

      case result do
        {:ok, _} ->
          {:noreply,
           socket |> assign(:show_form, false) |> load() |> put_flash(:info, "Customer saved")}

        {:error, changeset} ->
          {:noreply, assign(socket, :form, to_form(changeset, as: :customer))}
      end
    else
      {:noreply, put_flash(socket, :error, "Tenant administrator required")}
    end
  end

  defp load(socket),
    do:
      assign(
        socket,
        :organizations,
        Organizations.list(socket.assigns.current_scope)
      )

  def render(assigns) do
    ~H"""
    <div class="max-w-5xl mx-auto p-6 space-y-6">
      <.header>
        Customers<:subtitle>
          Customer organizations and individual customers in {@current_tenant.name}.
        </:subtitle><:actions>
          <.button :if={@current_role == "admin"} phx-click="show_form">Add customer</.button>
        </:actions>
      </.header>
      <.simple_form :if={@show_form} for={@form} id="customer-form" phx-submit="save_org">
        <.input field={@form[:name]} label="Customer name" required />
        <.input field={@form[:domain]} label="Business email domain (optional)" />
        <.input
          field={@form[:tier]}
          type="select"
          label="Tier"
          options={~w(standard basic enterprise)}
        />
        <:actions>
          <.button>Save customer</.button><button type="button" phx-click="hide_form">Cancel</button>
        </:actions>
      </.simple_form>
      <div class="grid md:grid-cols-2 gap-4">
        <article :for={org <- @organizations} class="rounded border p-4 space-y-2">
          <.link navigate={~p"/app/customers/#{org.id}"} class="font-semibold">{org.name}</.link>
          <p>{org.domain} · {org.tier}</p>
          <button :if={@current_role == "admin"} phx-click="edit_org" phx-value-id={org.id}>Edit customer</button>
        </article>
      </div>
    </div>
    """
  end
end
