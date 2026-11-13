defmodule CustyardWeb.Staff.AuditLogLive do
  @moduledoc "The tenant's audit timeline, for its admins. Stub: the page is built next."
  use CustyardWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :page_title, "Audit log")}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto w-full max-w-6xl px-3 py-4 sm:px-4" data-testid="staff-audit-page"></div>
    """
  end
end
