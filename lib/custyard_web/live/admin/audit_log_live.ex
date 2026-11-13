defmodule CustyardWeb.Admin.AuditLogLive do
  @moduledoc "The installation's audit timeline, for instance admins. Stub: the page is built next."
  use CustyardWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :page_title, "Audit log")}

  @impl true
  def render(assigns) do
    ~H"""
    <div data-testid="instance-admin-audit-page"></div>
    """
  end
end
