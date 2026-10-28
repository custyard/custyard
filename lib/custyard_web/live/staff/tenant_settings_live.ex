defmodule CustyardWeb.Staff.TenantSettingsLive do
  use CustyardWeb, :live_view
  import Ecto.Query
  alias Custyard.{StaffAccount, Repo, Tenants}
  alias CustyardWeb.Uploads

  def mount(_, _, socket) do
    if Tenants.can_manage?(socket.assigns.current_staff, socket.assigns.current_tenant) do
      {:ok,
       socket
       |> assign(:page_title, "Tenant settings")
       |> load()
       |> allow_upload(:logo,
         accept: ~w(.png .jpg .jpeg .svg .webp),
         max_entries: 1,
         max_file_size: 2_000_000
       ), layout: {CustyardWeb.Layouts, :staff}}
    else
      {:ok, redirect(socket, to: ~p"/app")}
    end
  end

  def handle_event("save", %{"tenant" => attrs}, socket) do
    if Tenants.can_manage?(socket.assigns.current_staff, socket.assigns.current_tenant) do
      save_tenant(socket, attrs)
    else
      {:noreply, put_flash(socket, :error, "Tenant administrator required")}
    end
  end

  def handle_event("validate", %{"tenant" => attrs}, socket) do
    changeset =
      Tenants.change_tenant(socket.assigns.current_tenant, Map.delete(attrs, "logo_url"))

    {:noreply,
     socket
     |> assign(:form, to_form(%{changeset | action: :validate}))
     |> assign(:remove_logo, attrs["remove_logo"] == "true")}
  end

  def handle_event("cancel_logo_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :logo, ref)}
  end

  def handle_event("invite", %{"staff" => attrs}, socket) do
    tenant = socket.assigns.current_tenant

    case Tenants.invite_staff(socket.assigns.current_staff, tenant.id, attrs) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load()
         |> put_flash(
           :info,
           "Staff account added. They can request a login link on the sign-in page."
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :staff_form, to_form(changeset, as: :staff))}

      {:error, :unauthorized} ->
        {:noreply, put_flash(socket, :error, "Tenant administrator required")}
    end
  end

  def handle_event("remove_staff", %{"id" => id}, socket) do
    with {staff_id, ""} <- Integer.parse(id),
         {:ok, _} <-
           Tenants.remove_staff(
             socket.assigns.current_staff,
             socket.assigns.current_tenant.id,
             staff_id
           ) do
      {:noreply, socket |> load() |> put_flash(:info, "Staff access removed")}
    else
      {:error, :self_removal} ->
        {:noreply, put_flash(socket, :error, "Ask another administrator to remove your access")}

      {:error, :last_admin} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Add another tenant administrator before removing this account"
         )}

      _ ->
        {:noreply, put_flash(socket, :error, "Could not remove staff access")}
    end
  end

  defp save_tenant(socket, attrs) do
    if logo_ready?(socket) do
      save_tenant_logo(socket, attrs)
    else
      {:noreply,
       put_flash(socket, :error, "Choose a logo under 2 MB and wait for the upload to finish")}
    end
  end

  defp save_tenant_logo(socket, attrs) do
    old_logo = socket.assigns.current_tenant.logo_url

    uploaded_logo =
      socket
      |> consume_uploaded_entries(:logo, fn %{path: path}, entry ->
        {:ok, Uploads.save_logo(path, entry.client_name)}
      end)
      |> List.first()

    logo = resolved_logo(attrs, uploaded_logo, old_logo)

    attrs = Map.put(attrs, "logo_url", logo)

    case Tenants.update_tenant_for_staff(
           socket.assigns.current_staff,
           socket.assigns.current_tenant.id,
           attrs
         ) do
      {:ok, tenant} ->
        if old_logo && old_logo != logo, do: Uploads.delete_logo(old_logo)

        {:noreply,
         socket
         |> assign(:current_tenant, tenant)
         |> load()
         |> put_flash(:info, "Tenant updated")}

      {:error, %Ecto.Changeset{} = changeset} ->
        if uploaded_logo, do: Uploads.delete_logo(uploaded_logo)
        {:noreply, assign(socket, :form, to_form(changeset))}

      {:error, :unauthorized} ->
        if uploaded_logo, do: Uploads.delete_logo(uploaded_logo)
        {:noreply, put_flash(socket, :error, "Tenant administrator required")}
    end
  end

  defp load(socket) do
    tenant = socket.assigns.current_tenant

    socket
    |> assign(:form, to_form(Tenants.change_tenant(tenant)))
    |> assign(:remove_logo, false)
    |> assign(:staff_form, to_form(%{"email" => "", "role" => "agent"}, as: :staff))
    |> assign(
      :staff,
      Repo.all(from o in StaffAccount, where: o.tenant_id == ^tenant.id, order_by: o.email)
    )
  end

  defp logo_ready?(socket) do
    upload_errors(socket.assigns.uploads.logo) == [] and
      Enum.all?(socket.assigns.uploads.logo.entries, fn entry ->
        entry.done? and upload_errors(socket.assigns.uploads.logo, entry) == []
      end)
  end

  defp resolved_logo(_attrs, uploaded, _old) when is_binary(uploaded), do: uploaded
  defp resolved_logo(%{"remove_logo" => "true"}, _uploaded, _old), do: nil
  defp resolved_logo(_attrs, _uploaded, old), do: old

  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto p-6 space-y-8">
      <.header>
        Tenant settings<:subtitle>{@current_tenant.name} · {Tenants.host(@current_tenant)}</:subtitle>
      </.header>
      <.simple_form for={@form} id="tenant-settings" phx-submit="save" phx-change="validate">
        <.input field={@form[:name]} label="Name" required />
        <p>Hostname changes are managed in the instance admin console.</p>
        <p class="text-sm">
          Point the domain at {Tenants.app_host()} and configure TLS with your hosting provider. Customer portal links keep their private token.
        </p>
        <div>
          <label for={@uploads.logo.ref} class="block text-sm font-semibold mb-2">Logo</label>
          <img
            :if={@current_tenant.logo_url}
            src={@current_tenant.logo_url}
            alt="Current tenant logo"
            class="h-12 w-auto mb-2"
            data-testid="tenant-logo-preview"
          />
          <.live_file_input upload={@uploads.logo} class="text-sm" />
          <p class="text-xs text-gray-500 mt-1">PNG, JPEG, SVG or WebP. Maximum 2 MB.</p>
          <div :for={entry <- @uploads.logo.entries} class="mt-2 text-sm">
            <span>{entry.client_name} · {entry.progress}%</span>
            <button
              type="button"
              phx-click="cancel_logo_upload"
              phx-value-ref={entry.ref}
              class="ml-2 text-indigo-600"
            >Cancel upload</button>
            <p :for={error <- upload_errors(@uploads.logo, entry)} role="alert" class="text-red-600">
              {upload_error(error)}
            </p>
          </div>
          <p :for={error <- upload_errors(@uploads.logo)} role="alert" class="text-red-600">
            {upload_error(error)}
          </p>
          <label :if={@current_tenant.logo_url} class="flex gap-2 items-center mt-2 text-sm">
            <input type="hidden" name="tenant[remove_logo]" value="false" />
            <input type="checkbox" name="tenant[remove_logo]" value="true" checked={@remove_logo} />
            Remove logo
          </label>
        </div>
        <.input field={@form[:primary_color]} label="Brand color (#RRGGBB)" />
        <:actions><.button>Save tenant</.button></:actions>
      </.simple_form>
      <.link navigate={~p"/app/settings/email"} class="text-indigo-600">Set up support email</.link>
      <section>
        <h2 class="font-semibold">Staff</h2>
        <p class="text-sm">Staff can work with every customer organization in this tenant.</p>
        <div
          :for={staff <- @staff}
          class="flex items-center justify-between gap-4 py-2"
          data-testid={"staff-#{staff.id}"}
        >
          <p>{staff.email} · {staff.role}</p>
          <button
            :if={staff.id != @current_staff.id}
            type="button"
            phx-click="remove_staff"
            phx-value-id={staff.id}
            data-confirm={"Remove access for #{staff.email}? Their staff account will be deleted. Conversation history stays available."}
            phx-disable-with="Removing..."
            class="text-sm text-red-700 dark:text-red-400"
            aria-label={"Remove staff account #{staff.email}"}
          >Remove</button>
        </div>
        <.simple_form for={@staff_form} id="tenant-staff" phx-submit="invite">
          <.input field={@staff_form[:email]} label="Staff email" type="email" required />
          <.input
            field={@staff_form[:role]}
            label="Role"
            type="select"
            options={[{"Agent", "agent"}, {"Administrator", "admin"}]}
          />
          <:actions><.button>Add staff account</.button></:actions>
        </.simple_form>
      </section>
    </div>
    """
  end

  defp upload_error(:too_large), do: "Logo must be under 2 MB"
  defp upload_error(:not_accepted), do: "Use PNG, JPEG, SVG or WebP"
  defp upload_error(:too_many_files), do: "Choose one logo"
  defp upload_error(_), do: "Logo upload failed; choose the file again"
end
