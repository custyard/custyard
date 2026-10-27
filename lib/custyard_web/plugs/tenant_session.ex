defmodule CustyardWeb.Plugs.TenantSession do
  @moduledoc "Carries the resolved host boundary into signed LiveView sessions."
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _) do
    put_session(conn, :host_tenant_id, conn.assigns[:host_tenant] && conn.assigns.host_tenant.id)
  end
end
