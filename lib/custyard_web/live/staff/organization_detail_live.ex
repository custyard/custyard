defmodule CustyardWeb.Staff.OrganizationDetailLive do
  @moduledoc "Customer contacts, threads, projects and independently revocable portal credentials."
  use CustyardWeb, :live_view
  import CustyardWeb.StaffComponents, only: [state_badge: 1]
  alias Custyard.{Acknowledgments, Threads, Organizations, PortalCredentials, Projects}

  def mount(%{"id" => id}, _, socket) do
    case Organizations.get_by_public_id(socket.assigns.current_scope, id) do
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
           :threads,
           Threads.list_for_organization(org.id, include_resolved: true, order: :recently_updated)
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

  def handle_event("set_default_contact", %{"contact_id" => contact_id}, socket) do
    case Organizations.update(socket.assigns.current_scope, socket.assigns.organization, %{
           default_contact_id: contact_id
         }) do
      {:ok, organization} ->
        {:noreply,
         socket
         |> assign(:organization, organization)
         |> put_flash(:info, "Default contact updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Choose a contact belonging to this customer")}
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
      <section aria-labelledby="customer-thread-history-title">
        <h2 id="customer-thread-history-title" class="font-semibold">Thread history</h2>
        <p class="mt-1 mb-3 text-sm text-gray-600 dark:text-zinc-300">
          Most recently updated first, including resolved threads.
        </p>
        <p :if={@threads == []}>No threads yet.</p>
        <ul id="customer-thread-history" class="divide-y divide-gray-200 dark:divide-zinc-700">
          <li
            :for={thread <- @threads}
            id={"customer-thread-#{thread.id}"}
            class="py-3 flex flex-wrap items-center justify-between gap-2"
          >
            <.link
              navigate={~p"/app/threads/#{thread.id}"}
              class="font-medium text-indigo-700 dark:text-indigo-300 hover:underline"
            >{thread.subject || "Untitled thread"}</.link>
            <div class="flex items-center gap-3 text-sm text-gray-600 dark:text-zinc-300">
              <.state_badge state={thread.state} />
              <time datetime={DateTime.to_iso8601(thread.updated_at)}>Updated {Calendar.strftime(
                thread.updated_at,
                "%Y-%m-%d %H:%M UTC"
              )}</time>
            </div>
          </li>
        </ul>
      </section>
      <section>
        <h2 class="font-semibold mb-3">Contacts</h2><p :if={@contacts == []}>No contacts yet.</p><p :for={
          contact <- @contacts
        }>
          {contact.name || contact.email} · {contact.email}
        </p>
        <form
          :if={@current_role == "admin" and @contacts != []}
          id="customer-default-contact-form"
          phx-submit="set_default_contact"
          class="mt-4 space-y-2"
        >
          <.input
            type="select"
            id="customer-default-contact"
            name="contact_id"
            value={@organization.default_contact_id || ""}
            label="Default contact for shared portal requests"
            prompt="No default contact"
            options={Enum.map(@contacts, &{&1.email, &1.id})}
          />
          <p class="text-sm text-gray-600 dark:text-zinc-300">
            Shared portal requests use this contact for email replies. A portal link issued for a specific contact uses that contact instead.
          </p>
          <.button>Save default contact</.button>
        </form>
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
          Anyone with a portal link can access this customer's shared requests and projects.
          Each link can be revoked independently.
        </p><p class="text-sm text-gray-600 dark:text-zinc-400">
          Contact attribution sets the name and reply address for requests made through this link.
          It does not verify who opens the link or limit access to that contact's requests.
        </p><form phx-submit="issue_portal" class="space-y-2">
          <.input
            type="select"
            id="portal-contact"
            name="contact_id"
            value=""
            label="Contact attribution (optional)"
            prompt="Use customer default contact"
            options={Enum.map(@contacts, &{&1.name || &1.email, &1.id})}
          />
          <.button>Issue portal link</.button>
        </form><p
          :if={@portal_url}
          class="break-all"
        >
          Copy this link now: {@portal_url}
        </p><p :for={credential <- @credentials}>
          {if credential.contact,
            do: "Contact attribution: #{credential.contact.name || credential.contact.email}",
            else: "Customer default contact"} ·
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
