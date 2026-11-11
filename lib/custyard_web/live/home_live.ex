defmodule CustyardWeb.HomeLive do
  use CustyardWeb, :live_view

  import Ecto.Query
  alias Custyard.{Repo, Tenant, TenantHost, Tenants}
  alias CustyardWeb.HostScope

  @impl true
  def mount(_params, _session, socket) do
    socket = HostScope.capture(socket)
    installation? = socket.assigns.verified_host == Tenants.normalize_host(Tenants.app_host())
    tenant = unless installation?, do: Tenants.resolve_host(socket.assigns.verified_host)

    cond do
      installation? ->
        {:ok, home_assigns(socket, nil, true)}

      tenant && tenant.status == "active" ->
        {:ok, home_assigns(socket, tenant, false)}

      true ->
        {:ok, redirect(socket, external: CustyardWeb.Endpoint.url())}
    end
  end

  defp home_assigns(socket, tenant, installation?) do
    assign(socket,
      host_tenant: tenant,
      current_tenant: tenant,
      installation_host: installation?,
      workspace_slug: "",
      workspace_error: nil
    )
  end

  @impl true
  def handle_event("find_workspace", %{"workspace" => %{"slug" => slug}}, socket) do
    if socket.assigns.installation_host do
      slug = slug |> String.trim() |> String.downcase()

      case workspace_host(slug) do
        nil ->
          {:noreply,
           assign(socket,
             workspace_slug: slug,
             workspace_error: "Workspace unavailable. Check the workspace name and try again."
           )}

        host ->
          url =
            CustyardWeb.Endpoint.url()
            |> URI.parse()
            |> Map.merge(%{host: host, path: "/app/login", query: nil, fragment: nil})
            |> URI.to_string()

          {:noreply, redirect(socket, external: url)}
      end
    else
      {:noreply, socket}
    end
  end

  defp workspace_host(slug) do
    if Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/, slug) do
      Repo.one(
        from h in TenantHost,
          join: t in Tenant,
          on: t.id == h.tenant_id,
          where:
            t.slug == ^slug and t.status == "active" and
              h.hostname != ^Tenants.normalize_host(Tenants.app_host()),
          order_by: h.id,
          limit: 1,
          select: h.hostname
      )
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-xl py-12" data-testid="home-container">
      <%= if @installation_host do %>
        <.header>
          Customer onboarding, with support in one place
          <:subtitle>
            Custyard is an open-source platform for onboarding and supporting your customers.
          </:subtitle>
        </.header>
        <p class="mt-5 text-gray-600 dark:text-zinc-300">
          Bring customer emails into shared threads, organize work by customer,
          and track follow-up tasks. Give customers a private portal for updates and requests.
        </p>
        <section class="mt-8 rounded-lg border border-zinc-200 dark:border-zinc-700 p-6">
          <h2 class="text-lg font-semibold text-zinc-900 dark:text-zinc-100">Find your workspace</h2>
          <p class="mt-2 text-sm text-gray-600 dark:text-zinc-400">
            Enter your workspace name to continue to staff sign in.
          </p>
          <form id="workspace-finder" phx-submit="find_workspace" class="mt-4 space-y-3">
            <label for="workspace-slug" class="block text-sm font-medium">Workspace name</label>
            <input
              id="workspace-slug"
              name="workspace[slug]"
              value={@workspace_slug}
              type="text"
              required
              maxlength="63"
              autocomplete="off"
              autocapitalize="none"
              spellcheck="false"
              placeholder="your-team"
              class="w-full rounded-md border border-gray-300 dark:border-zinc-600 bg-white dark:bg-zinc-800 px-3 py-2"
            />
            <p :if={@workspace_error} role="alert" class="text-sm text-red-600 dark:text-red-400">
              {@workspace_error}
            </p>
            <button
              type="submit"
              class="rounded bg-indigo-600 px-4 py-2 text-sm font-medium text-white hover:bg-indigo-700"
            >Continue to workspace</button>
          </form>
        </section>
        <p class="mt-6 text-sm text-gray-500 dark:text-zinc-400">
          Manage this installation?
          <.link href={~p"/admin/login"} class="underline">Instance admin sign in</.link>
        </p>
      <% else %>
        <.header class="text-center">
          <img
            :if={@current_tenant.logo_url}
            src={@current_tenant.logo_url}
            alt=""
            class="h-16 w-auto mx-auto mb-4"
          /> Welcome to {@current_tenant.name}
          <:subtitle>Support threads, shared updates and follow-up tasks</:subtitle>
        </.header>
        <div class="mt-8 text-center space-y-4">
          <.link
            navigate={~p"/app/login"}
            class="inline-block px-4 py-2 bg-indigo-600 text-white text-sm font-medium rounded hover:bg-indigo-700"
            data-testid="home-staff-login-link"
          >Staff sign in</.link>
          <p class="text-sm text-gray-500 dark:text-zinc-400" data-testid="home-portal-info">
            Customers: open the private thread or portal link shared with you.
          </p>
        </div>
      <% end %>
    </div>
    """
  end
end
