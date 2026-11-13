defmodule CustyardWeb.Admin.AuditLogLive do
  @moduledoc """
  The installation's audit timeline, for instance admins: installation events
  and what instance admins did to a tenant.

  `Custyard.AuditLog.for_instance/2` decides what is listed and builds every
  entry. The page loads nothing else, so it shows nothing of a tenant beyond
  the name an entry carries.

  The `before` parameter is the id of an entry; the page lists the events
  older than it. Anything that is not a positive integer is ignored.

  The page does not update live. It subscribes to nothing, so an event
  written while the page is open shows after the next navigation or reload.
  """
  use CustyardWeb, :live_view

  import CustyardWeb.AuditLogComponents

  alias Custyard.AuditLog

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :page_title, "Audit log")}

  @impl true
  def handle_params(params, _uri, socket) do
    before = AuditLog.parse_id(params["before"])

    case AuditLog.for_instance(socket.assigns.current_instance_admin, before: before) do
      {:ok, %{entries: entries, older: older}} ->
        {:noreply,
         assign(socket,
           entries: entries,
           before: before,
           older_path: older && ~p"/admin/audit?#{[before: older]}"
         )}

      {:error, :unauthorized} ->
        {:noreply, redirect(socket, to: ~p"/admin/login")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div data-testid="instance-admin-audit-page">
      <.header>
        Audit log
        <:subtitle>
          Installation events and what instance admins did to a tenant. What happens inside a tenant is in that workspace's own audit log, under Settings. Times are UTC.
        </:subtitle>
      </.header>

      <p :if={@before} class="mt-4 text-sm">
        <.link
          patch={~p"/admin/audit"}
          class="text-indigo-700 hover:underline dark:text-indigo-300"
          data-testid="instance-admin-audit-newest-link"
        >
          Back to the newest events
        </.link>
      </p>

      <div class="mt-6">
        <.timeline entries={@entries} audience={:instance} older_path={@older_path} />
      </div>
    </div>
    """
  end
end
