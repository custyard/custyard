defmodule CustyardWeb.Operator.SlugsLive do
  @moduledoc """
  Super-admin administration of the slug registry.

  Lists every registry row (slug, status, anchor email, expiry, linked
  conversation) and releases claimed/confirmed rows back to available.
  Provisioned rows are refused — a provisioned slug is an organization's
  portal identity and is released only by organization deletion.

  Mount is gated to super admins by the router live_session, and the
  mutating event re-checks `Authorization.can_modify_settings?/1`
  (settings double-gate pattern). Every release writes a `:slug_released`
  audit event.
  """

  use CustyardWeb, :live_view

  require Logger

  alias Custyard.{AuditEvent, Authorization, Slug, Slugs}

  @permission_error "Only super admins can release slugs"

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Slugs")
      |> load_slugs()

    {:ok, socket, layout: {CustyardWeb.Layouts, :operator}}
  end

  @impl true
  def handle_event("release", %{"id" => id}, socket) do
    if Authorization.can_modify_settings?(socket.assigns.current_operator) do
      release_slug(socket, id)
    else
      {:noreply, put_flash(socket, :error, @permission_error)}
    end
  end

  defp release_slug(socket, id) do
    case Slugs.get_slug(id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Slug not found")
         |> load_slugs()}

      %Slug{} = slug ->
        handle_release_result(socket, slug, Slugs.release(slug))
    end
  end

  defp handle_release_result(socket, _slug, {:ok, released}) do
    record_release_audit(released, socket.assigns.current_operator)

    {:noreply,
     socket
     |> put_flash(:info, "Slug \"#{released.slug}\" released")
     |> load_slugs()}
  end

  defp handle_release_result(socket, _slug, {:error, :provisioned}) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "Provisioned slugs belong to an organization and are released by deleting it"
     )}
  end

  defp handle_release_result(socket, _slug, {:error, :not_found}) do
    # The row changed underneath the click (released elsewhere, expired and
    # swept, or promoted) — just refresh.
    {:noreply, load_slugs(socket)}
  end

  # Append-only audit trail for the release (AuditEvent.create pattern).
  # An audit write failure is logged, never blocks the release.
  defp record_release_audit(slug, operator) do
    case AuditEvent.create(%{
           event_type: :slug_released,
           source: "operator",
           payload: %{
             "slug" => slug.slug,
             "status" => Atom.to_string(slug.status),
             "email" => slug.email,
             "operator_id" => operator.id,
             "operator_email" => operator.email
           },
           conversation_id: slug.conversation_id
         }) do
      {:ok, _event} ->
        :ok

      {:error, changeset} ->
        Logger.error("Failed to record slug release audit event: #{inspect(changeset.errors)}")
        :ok
    end
  end

  defp load_slugs(socket) do
    assign(socket, :slugs, Slugs.list_slugs())
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto p-4 overflow-y-auto" data-testid="operator-slugs-page">
      <h1
        class="text-lg font-semibold text-gray-900 dark:text-zinc-100 mb-6"
        data-testid="operator-slugs-heading"
      >
        Slugs
      </h1>

      <div :if={@slugs == []} class="text-center py-12" data-testid="operator-slugs-empty">
        <p class="text-gray-600 dark:text-zinc-400 text-sm">No slugs claimed yet</p>
      </div>

      <div :if={@slugs != []} class="space-y-2">
        <div
          :for={slug <- @slugs}
          class="bg-white dark:bg-zinc-800 border border-gray-200 dark:border-zinc-700 rounded-lg p-4 flex items-center justify-between gap-4"
          data-testid={"operator-slug-row-#{slug.id}"}
        >
          <div class="min-w-0">
            <div class="flex items-center gap-2">
              <span class="font-mono text-sm font-semibold text-gray-900 dark:text-zinc-100">
                {slug.slug}
              </span>
              <span
                class={"text-xs px-2 py-0.5 rounded-full #{status_badge(slug.status)}"}
                data-testid={"operator-slug-status-#{slug.id}"}
              >
                {status_label(slug.status)}
              </span>
            </div>
            <div class="mt-1 text-xs text-gray-500 dark:text-zinc-400 space-x-3">
              <span :if={slug.email} data-testid={"operator-slug-email-#{slug.id}"}>
                {slug.email}
              </span>
              <span :if={slug.expires_at} data-testid={"operator-slug-expiry-#{slug.id}"}>
                expires {format_time(slug.expires_at)}
              </span>
              <.link
                :if={slug.conversation_id}
                navigate={~p"/operator/conversation/#{slug.conversation_id}"}
                class="text-indigo-600 dark:text-indigo-400 hover:underline"
                data-testid={"operator-slug-conversation-#{slug.id}"}
              >
                View conversation
              </.link>
            </div>
          </div>
          <button
            :if={slug.status in [:claimed, :confirmed]}
            phx-click="release"
            phx-value-id={slug.id}
            data-confirm={"Release the slug \"#{slug.slug}\"? It becomes claimable by anyone."}
            class="shrink-0 text-sm text-red-600 dark:text-red-400 border border-red-200 dark:border-red-900 px-3 py-1.5 rounded hover:bg-red-50 dark:hover:bg-red-950"
            data-testid={"operator-slug-release-#{slug.id}"}
          >
            Release
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp status_badge(:claimed),
    do: "bg-yellow-100 dark:bg-yellow-950 text-yellow-800 dark:text-yellow-300"

  defp status_badge(:confirmed),
    do: "bg-green-100 dark:bg-green-950 text-green-800 dark:text-green-300"

  defp status_badge(:provisioned),
    do: "bg-indigo-100 dark:bg-indigo-950 text-indigo-800 dark:text-indigo-300"

  defp status_label(:claimed), do: "Provisional"
  defp status_label(:confirmed), do: "Confirmed"
  defp status_label(:provisioned), do: "Provisioned"

  defp format_time(datetime), do: Calendar.strftime(datetime, "%b %d, %H:%M")
end
