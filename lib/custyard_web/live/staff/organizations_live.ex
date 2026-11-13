defmodule CustyardWeb.Staff.OrganizationsLive do
  use CustyardWeb, :live_view

  import CustyardWeb.StaffComponents, only: [tier_badge: 1]

  alias Custyard.{Authorization, Organizations}

  def mount(_, _, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Customers")
     |> assign(:editing_org, nil)
     |> assign(:show_form, false)
     |> assign(:form, blank_form())
     |> load(), layout: {CustyardWeb.Layouts, :staff}}
  end

  # A blank form each time, or "Add customer" would open with the values of
  # the customer edited last.
  def handle_event("show_form", _, socket) do
    {:noreply,
     socket
     |> assign(:show_form, true)
     |> assign(:editing_org, nil)
     |> assign(:form, blank_form())}
  end

  def handle_event("hide_form", _, socket), do: {:noreply, assign(socket, :show_form, false)}

  def handle_event("edit_org", %{"id" => id}, socket) do
    org = Organizations.get(socket.assigns.current_scope, id)

    cond do
      is_nil(org) ->
        {:noreply, put_flash(socket, :error, "Customer unavailable")}

      not Authorization.can_manage_organization?(socket.assigns.current_staff, org.id) ->
        {:noreply, put_flash(socket, :error, "Tenant administrator required")}

      true ->
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

  defp blank_form,
    do: to_form(%{"name" => "", "domain" => "", "tier" => "standard"}, as: :customer)

  defp load(socket),
    do:
      assign(
        socket,
        :organizations,
        Organizations.list(socket.assigns.current_scope)
      )

  # What tells this customer apart: the business domain, or the address of a
  # personal sender. A customer added by hand without a domain has neither.
  defp identity(%{domain: domain}) when is_binary(domain) and domain != "", do: domain
  defp identity(%{identity_kind: :email, identity_value: email}), do: email
  defp identity(_org), do: nil

  # The page follows the attention queue: the same container and heading row,
  # then one bordered list. The standard button is 40px tall, too tall for
  # that heading row, so it gets less padding here. The `!` is needed because
  # the button's own padding classes would otherwise win.
  def render(assigns) do
    assigns = assign(assigns, :count, length(assigns.organizations))

    ~H"""
    <div class="mx-auto w-full max-w-6xl px-3 py-4 sm:px-4" data-testid="staff-customers-page">
      <div class="mb-3 flex items-center justify-between gap-3">
        <h1
          class="text-lg font-semibold text-gray-900 dark:text-zinc-100"
          data-testid="staff-customers-heading"
        >
          Customers
        </h1>
        <div class="flex items-center gap-4 text-xs text-gray-600 dark:text-zinc-400">
          <span data-testid="staff-customers-count">
            {@count} {if @count == 1, do: "customer", else: "customers"}
          </span>
          <.button
            :if={@current_role == "admin"}
            type="button"
            phx-click="show_form"
            class="py-1! leading-5!"
          >
            Add customer
          </.button>
        </div>
      </div>

      <%!-- A new id for each customer being edited, so the form scrolls into
      view again when the admin picks another row. --%>
      <div
        :if={@show_form}
        id={"customer-form-card-#{if @editing_org, do: @editing_org.id, else: "new"}"}
        phx-hook="ScrollIntoView"
        class="mb-3 rounded-lg border border-gray-200 bg-white p-4 dark:border-zinc-700 dark:bg-zinc-800"
        data-testid="staff-customer-form-card"
      >
        <h2 class="mb-2 text-sm font-semibold text-gray-900 dark:text-zinc-100">
          {if @editing_org, do: "Edit customer", else: "Add customer"}
        </h2>
        <.form
          for={@form}
          id="customer-form"
          phx-submit="save_org"
          class="grid gap-x-4 gap-y-3 sm:grid-cols-3"
        >
          <.input field={@form[:name]} label="Customer name" required />
          <.input field={@form[:domain]} label="Business email domain (optional)" />
          <.input
            field={@form[:tier]}
            type="select"
            label="Tier"
            options={~w(standard basic enterprise)}
          />
          <div class="flex items-center gap-2 sm:col-span-3">
            <.button class="py-1! leading-5!">Save customer</.button>
            <button
              type="button"
              phx-click="hide_form"
              class="rounded-lg px-3 py-1 text-sm text-gray-600 hover:bg-gray-100 focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-indigo-500 dark:text-zinc-300 dark:hover:bg-zinc-700"
              data-testid="staff-customer-cancel-btn"
            >
              Cancel
            </button>
          </div>
        </.form>
      </div>

      <div
        :if={@count == 0}
        class="rounded-lg border border-gray-200 bg-white py-12 text-center text-gray-500 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-400"
        data-testid="staff-customers-empty"
      >
        No customers yet.
      </div>
      <ul
        :if={@count > 0}
        role="list"
        class="divide-y divide-gray-200 overflow-hidden rounded-lg border border-gray-200 bg-white dark:divide-zinc-700 dark:border-zinc-700 dark:bg-zinc-800"
        data-testid="staff-customers-list"
      >
        <%!-- The link is the whole row. The edit button sits beside it, never
        inside it, in the space the row keeps free on the right. --%>
        <li
          :for={org <- @organizations}
          id={"customer-#{org.id}"}
          class="group relative"
          data-testid={"staff-customer-row-#{org.id}"}
        >
          <.link
            navigate={~p"/app/customers/#{org.public_id}"}
            class={[
              "flex items-center gap-3 px-3 py-2.5 hover:bg-gray-50 focus:bg-indigo-50 focus-visible:outline-2 focus-visible:-outline-offset-2 focus-visible:outline-indigo-500 dark:hover:bg-zinc-700/40 dark:focus:bg-indigo-950/40",
              @current_role == "admin" && "pr-12"
            ]}
            data-testid="staff-customer-link"
          >
            <span class="flex min-w-0 flex-1 flex-col md:flex-row md:items-baseline md:gap-3">
              <span
                class="truncate text-sm font-medium leading-5 text-gray-900 dark:text-zinc-100 md:w-72 md:shrink-0"
                data-testid="staff-customer-name"
              >
                {org.name}
              </span>
              <span
                :if={identity = identity(org)}
                class="truncate text-xs leading-5 text-gray-500 dark:text-zinc-400"
                data-testid="staff-customer-identity"
              >
                {identity}
              </span>
            </span>
            <.tier_badge tier={org.tier} />
          </.link>
          <div
            :if={@current_role == "admin"}
            class="hover-reveal absolute inset-y-0 right-2 flex items-center"
          >
            <button
              type="button"
              phx-click="edit_org"
              phx-value-id={org.id}
              aria-label={"Edit #{org.name}"}
              title="Edit customer"
              class="flex h-8 w-8 items-center justify-center rounded text-gray-500 hover:bg-gray-200 hover:text-gray-900 focus-visible:outline-2 focus-visible:outline-indigo-500 dark:text-zinc-400 dark:hover:bg-zinc-600 dark:hover:text-zinc-100 md:h-7 md:w-7"
              data-testid={"staff-customer-edit-#{org.id}"}
            >
              <.icon name="hero-pencil-square-mini" class="h-4 w-4" />
            </button>
          </div>
        </li>
      </ul>
    </div>
    """
  end
end
