defmodule CustyardWeb.Plugs.RequireStaff do
  @moduledoc "Requires a tenant staff session belonging to the current registered hostname."
  import Plug.Conn
  import Phoenix.Controller
  alias Custyard.{Scope, Tenants}
  alias CustyardWeb.Live.StaffAuth
  def init(opts), do: opts

  def call(conn, _) do
    staff =
      StaffAuth.session_staff(
        get_session(conn, :staff_id),
        get_session(conn, :staff_claim)
      )

    scope = staff && Scope.for_staff(staff, conn.assigns[:host_tenant])

    if scope && Tenants.active?(scope.tenant_id) do
      conn |> assign(:current_staff, staff) |> assign(:current_scope, scope)
    else
      conn
      |> delete_session(:staff_id)
      |> delete_session(:staff_claim)
      |> put_flash(:error, "Please sign in to this workspace")
      |> redirect(to: "/app/login")
      |> halt()
    end
  end
end
