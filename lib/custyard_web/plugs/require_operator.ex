defmodule CustyardWeb.Plugs.RequireOperator do
  @moduledoc "Requires a tenant staff session belonging to the current registered hostname."
  import Plug.Conn
  import Phoenix.Controller
  alias Custyard.{Scope, Tenants}
  alias CustyardWeb.Live.OperatorAuth
  def init(opts), do: opts

  def call(conn, _) do
    staff =
      OperatorAuth.session_operator(
        get_session(conn, :operator_id),
        get_session(conn, :operator_claim)
      )

    scope = staff && Scope.for_staff(staff, conn.assigns[:host_tenant])

    if scope && Tenants.active?(scope.tenant_id) do
      conn |> assign(:current_operator, staff) |> assign(:current_scope, scope)
    else
      conn
      |> delete_session(:operator_id)
      |> delete_session(:operator_claim)
      |> put_flash(:error, "Please sign in to this workspace")
      |> redirect(to: "/app/login")
      |> halt()
    end
  end
end
