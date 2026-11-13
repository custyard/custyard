defmodule CustyardWeb.Staff.AuditLogLive do
  @moduledoc """
  The tenant's audit timeline, for its admins: who did what in the workspace.

  The filter, the conversation and the page are kept in the URL (`filter`,
  `thread` and `before`), so a view can be linked to and the back button
  works.

  The page does not update live. It subscribes to nothing: a new event shows
  after a reload, or the next time the filter or the page changes.
  """
  use CustyardWeb, :live_view

  import CustyardWeb.AuditLogComponents, only: [timeline: 1, thread_subject: 1]
  import CustyardWeb.StaffComponents, only: [filter_chip: 1]

  alias Custyard.AuditLog

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :page_title, "Audit log")}

  @impl true
  def handle_params(params, _uri, socket) do
    filter = AuditLog.category(params["filter"])
    thread_id = AuditLog.parse_id(params["thread"])
    before = AuditLog.parse_id(params["before"])

    case AuditLog.for_tenant(socket.assigns.current_scope,
           category: filter,
           thread_id: thread_id,
           before: before
         ) do
      {:ok, page} ->
        socket =
          socket
          |> assign(:filter, filter)
          |> assign(:thread_id, thread_id)
          |> assign(:thread, page.thread)
          |> assign(:entries, page.entries)
          |> assign(:before, before)
          |> assign(:older_path, page.older && audit_path(filter, thread_id, page.older))

        {:noreply, socket}

      {:error, :unauthorized} ->
        {:noreply, redirect(socket, to: ~p"/app")}
    end
  end

  # A chip keeps the conversation and starts again at the newest events.
  @impl true
  def handle_event("filter", %{"filter" => id}, socket) do
    path = audit_path(AuditLog.category(id), socket.assigns.thread_id)
    {:noreply, push_patch(socket, to: path)}
  end

  # The page's path for a filter, a conversation and where the page starts.
  # Every link and patch is built here. What is at its default is left out,
  # so the plain page keeps the plain address.
  defp audit_path(filter, thread_id, before \\ nil) do
    params =
      Enum.reject(
        [
          filter: if(filter != AuditLog.default_category(), do: filter),
          thread: thread_id,
          before: before
        ],
        fn {_key, value} -> is_nil(value) end
      )

    ~p"/app/settings/audit?#{params}"
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-full max-w-6xl px-3 py-4 sm:px-4" data-testid="staff-audit-page">
      <div class="mb-3 flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
        <h1
          class="text-lg font-semibold text-gray-900 dark:text-zinc-100"
          data-testid="staff-audit-heading"
        >
          Audit log
        </h1>
        <p class="text-xs text-gray-600 dark:text-zinc-400" data-testid="staff-audit-intro">
          Who did what in this workspace. Times are UTC.
        </p>
      </div>

      <div
        class="mb-3 flex flex-wrap gap-1.5"
        role="group"
        aria-label="Filter by kind of event"
        data-testid="staff-audit-filters"
      >
        <.filter_chip
          :for={category <- AuditLog.categories()}
          current={@filter}
          value={category.id}
          label={category.label}
          testid="staff-audit-filter"
        />
      </div>

      <div
        :if={@thread_id}
        class="mb-3 flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1 rounded-lg border border-gray-200 bg-white px-3 py-2 text-sm text-gray-700 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-300"
        data-testid="staff-audit-thread-filter"
      >
        <p :if={@thread} class="min-w-0 break-words">
          Events of the conversation
          <.link
            navigate={~p"/app/threads/#{@thread.id}"}
            class="font-medium text-indigo-700 hover:underline dark:text-indigo-300"
            data-testid="staff-audit-thread-link"
          >
            {thread_subject(@thread)}
          </.link>
        </p>
        <p :if={!@thread}>This conversation was not found.</p>
        <.link
          patch={audit_path(@filter, nil)}
          class="text-indigo-700 hover:underline dark:text-indigo-300"
          data-testid="staff-audit-thread-clear"
        >
          Show every conversation
        </.link>
      </div>

      <p :if={@before} class="mb-3 text-sm">
        <.link
          patch={audit_path(@filter, @thread_id)}
          class="text-indigo-700 hover:underline dark:text-indigo-300"
          data-testid="staff-audit-newest-link"
        >
          Back to the newest events
        </.link>
      </p>

      <.timeline entries={@entries} audience={:tenant} older_path={@older_path} />
    </div>
    """
  end
end
