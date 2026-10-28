defmodule CustyardWeb.Staff.OrganizationDetailLive do
  @moduledoc "Customer contacts, threads, projects and independently revocable portal credentials."
  use CustyardWeb, :live_view
  alias Custyard.{Acknowledgments, Conversations, Organizations, PortalCredentials, Projects}

  def mount(%{"id" => id}, _, socket) do
    case Organizations.get(socket.assigns.current_scope, id) do
      nil ->
        {:ok,
         socket |> put_flash(:error, "Customer unavailable") |> redirect(to: ~p"/app/customers")}

      org ->
        {:ok,
         socket
         |> assign(:organization, org)
         |> assign(:page_title, org.name)
         |> assign(:portal_url, nil)
         |> assign(:contacts, Organizations.list_contacts(socket.assigns.current_scope, org.id))
         |> assign(
           :conversations,
           Conversations.list_for_organization(org.id, include_resolved: true)
         )
         |> assign(
           :projects,
           Projects.list_for_organization(socket.assigns.current_scope, org.id)
         )
         |> assign(
           :acknowledgments,
           Acknowledgments.list_for_organization(socket.assigns.current_scope, org.id, limit: 50)
         )
         |> assign(
           :bindings,
           Acknowledgments.list_bindings_for_organization(socket.assigns.current_scope, org.id)
         )
         |> load_credentials(), layout: {CustyardWeb.Layouts, :staff}}
    end
  end

  def handle_event("issue_portal", params, socket) do
    if socket.assigns.current_role == "admin" do
      case PortalCredentials.issue(
             socket.assigns.current_scope,
             socket.assigns.organization.id,
             contact_id(params["contact_id"])
           ) do
        {:ok, _, token} ->
          {:noreply,
           socket
           |> assign(
             :portal_url,
             Custyard.Tenants.url(socket.assigns.current_tenant) <> "/portal/" <> token
           )
           |> load_credentials()}

        _ ->
          {:noreply, put_flash(socket, :error, "Could not issue portal access")}
      end
    else
      {:noreply, put_flash(socket, :error, "Tenant administrator required")}
    end
  end

  def handle_event("revoke_portal", %{"id" => id}, socket) do
    credential = Enum.find(socket.assigns.credentials, &(to_string(&1.id) == id))

    if socket.assigns.current_role == "admin" and credential do
      PortalCredentials.revoke(socket.assigns.current_scope, credential)
      {:noreply, socket |> assign(:portal_url, nil) |> load_credentials()}
    else
      {:noreply, put_flash(socket, :error, "Portal credential unavailable")}
    end
  end

  defp contact_id(value) when value in [nil, ""], do: nil

  defp contact_id(value) do
    case Integer.parse(value) do
      {id, ""} when id > 0 -> id
      _ -> -1
    end
  end

  defp load_credentials(socket),
    do:
      assign(
        socket,
        :credentials,
        PortalCredentials.list(socket.assigns.current_scope, socket.assigns.organization.id)
      )

  def render(assigns) do
    ~H"""
    <div class="max-w-5xl mx-auto p-6 space-y-8">
      <.link navigate={~p"/app/customers"}>Customers</.link>
      <.header>
        {@organization.name}
        <:subtitle>{@organization.domain} · {@organization.tier}</:subtitle>
      </.header>
      <section>
        <h2 class="font-semibold mb-3">Threads</h2><p :if={@conversations == []}>No threads yet.</p><p :for={
          thread <- @conversations
        }>
          <.link navigate={~p"/app/threads/#{thread.id}"}>{thread.subject || "Untitled thread"}</.link>
          · {thread.state}
        </p>
      </section>
      <section>
        <h2 class="font-semibold mb-3">Contacts</h2><p :if={@contacts == []}>No contacts yet.</p><p :for={
          contact <- @contacts
        }>
          {contact.name || contact.email} · {contact.email}
        </p>
      </section>
      <section>
        <h2 class="font-semibold mb-3">Projects</h2><p :if={@projects == []}>No projects yet.</p><p :for={
          project <- @projects
        }>
          <.link navigate={~p"/app/projects/#{project.id}"}>{project.title}</.link>
        </p>
      </section>
      <section class="space-y-3">
        <h2 class="font-semibold">Acknowledgments</h2>
        <p :for={binding <- @bindings}>{binding.source} · {binding.source_organization_id}</p>
        <p :for={record <- @acknowledgments}>
          {record.statement_key} · {record.statement_version} · {record.acknowledged_at}
        </p>
      </section>
      <section :if={@current_role == "admin"} class="space-y-3">
        <h2 class="font-semibold">Portal access</h2><p>
          Each credential grants access to this customer's portal and can be revoked independently.
        </p><form phx-submit="issue_portal" class="space-y-2">
          <label>
            Contact attribution (optional)
            <select name="contact_id"><option value="">Shared customer access</option><option
              :for={contact <- @contacts}
              value={contact.id}
            >
              {contact.name || contact.email}
            </option></select>
          </label>
          <.button>Issue portal link</.button>
        </form><p
          :if={@portal_url}
          class="break-all"
        >
          Copy this link now: {@portal_url}
        </p><p :for={credential <- @credentials}>
          Issued {credential.inserted_at} {if credential.revoked_at, do: "· revoked", else: "· active"}
          <button
            :if={is_nil(credential.revoked_at)}
            phx-click="revoke_portal"
            phx-value-id={credential.id}
          >Revoke</button>
        </p>
      </section>
    </div>
    """
  end
end
