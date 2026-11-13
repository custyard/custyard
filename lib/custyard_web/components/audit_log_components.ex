defmodule CustyardWeb.AuditLogComponents do
  @moduledoc """
  The audit timeline as a list, shared by the tenant admin page and the
  instance admin page. It renders `Custyard.AuditLog.Entry` structs and reads
  nothing else.
  """
  use CustyardWeb, :html

  alias Custyard.AuditLog

  @doc """
  The entries, newest first, with a link to the next page.

  `audience` is who reads it. A tenant admin (`:tenant`) gets links to the
  thread and the customer of an entry. An instance admin (`:instance`) gets
  the tenant an entry belongs to, or "Installation".

  `older_path` is the path of the next page, nil on the last one. The link is
  a patch, so the page keeps its LiveView.

  Test ids: `audit-timeline`, `audit-empty`, `audit-entry-<id>` and inside
  it `audit-entry-time`, `-actor`, `-summary`, `-topic`, `-thread`,
  `-customer` and `-tenant`; `audit-older-link`.

  ## Examples

      <.timeline entries={@entries} audience={:tenant} older_path={@older_path} />
  """
  attr :entries, :list, required: true, doc: "Custyard.AuditLog.Entry structs"
  attr :audience, :atom, required: true, values: [:tenant, :instance]
  attr :older_path, :string, default: nil

  def timeline(assigns) do
    ~H"""
    <div
      :if={@entries == []}
      class="rounded-lg border border-gray-200 bg-white py-12 text-center text-sm text-gray-600 dark:border-zinc-700 dark:bg-zinc-800 dark:text-zinc-400"
      data-testid="audit-empty"
    >
      No events to show.
    </div>

    <ul
      :if={@entries != []}
      role="list"
      class="divide-y divide-gray-200 rounded-lg border border-gray-200 bg-white dark:divide-zinc-700 dark:border-zinc-700 dark:bg-zinc-800"
      data-testid="audit-timeline"
    >
      <li
        :for={entry <- @entries}
        class="flex flex-col gap-x-4 gap-y-1 px-3 py-2.5 sm:flex-row sm:items-baseline"
        data-testid={"audit-entry-#{entry.id}"}
      >
        <time
          datetime={DateTime.to_iso8601(entry.at)}
          class="shrink-0 text-xs tabular-nums text-gray-600 sm:w-40 dark:text-zinc-400"
          data-testid="audit-entry-time"
        >
          {Calendar.strftime(entry.at, "%Y-%m-%d %H:%M:%S")} UTC
        </time>

        <div class="min-w-0 flex-1">
          <p class="text-sm text-gray-900 dark:text-zinc-100">
            <span class="font-medium break-words" data-testid="audit-entry-actor">{entry.actor}</span>
            <span class="break-words" data-testid="audit-entry-summary">{entry.summary}</span>
          </p>
          <p
            :if={context?(entry, @audience)}
            class="mt-0.5 flex flex-wrap gap-x-3 gap-y-0.5 text-xs text-gray-600 dark:text-zinc-400"
          >
            <.link
              :if={@audience == :tenant and entry.thread}
              navigate={~p"/app/threads/#{entry.thread.id}"}
              class="max-w-full truncate text-indigo-700 hover:underline dark:text-indigo-300"
              data-testid="audit-entry-thread"
            >
              {subject(entry.thread)}
            </.link>
            <.link
              :if={@audience == :tenant and entry.customer}
              navigate={~p"/app/customers/#{entry.customer.id}"}
              class="max-w-full truncate hover:underline"
              data-testid="audit-entry-customer"
            >
              {entry.customer.name}
            </.link>
            <.link
              :if={@audience == :instance and entry.tenant}
              navigate={~p"/admin/tenants/#{entry.tenant.id}/settings"}
              class="max-w-full truncate text-indigo-700 hover:underline dark:text-indigo-300"
              data-testid="audit-entry-tenant"
            >
              {entry.tenant.name || "Tenant #{entry.tenant.id}"}
            </.link>
            <span :if={@audience == :instance and !entry.tenant} data-testid="audit-entry-tenant">
              Installation
            </span>
          </p>
        </div>

        <span
          class="shrink-0 text-xs text-gray-600 dark:text-zinc-400"
          data-testid="audit-entry-topic"
        >
          {AuditLog.topic_label(entry.topic)}
        </span>
      </li>
    </ul>

    <p :if={@older_path} class="mt-3 text-sm">
      <.link
        patch={@older_path}
        class="text-indigo-700 hover:underline dark:text-indigo-300"
        data-testid="audit-older-link"
      >
        Older events
      </.link>
    </p>
    """
  end

  defp context?(entry, :tenant), do: entry.thread != nil or entry.customer != nil
  defp context?(_entry, :instance), do: true

  defp subject(%{subject: subject}) when is_binary(subject) do
    if String.trim(subject) == "", do: "(no subject)", else: subject
  end

  defp subject(_thread), do: "(no subject)"
end
