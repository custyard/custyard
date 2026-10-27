defmodule CustyardWeb.Operator.TenantController do
  use CustyardWeb, :controller

  def select(conn, %{"id" => id}) do
    if Custyard.OperatorAccount.super_admin?(conn.assigns.current_operator) do
      case Integer.parse(id) do
        {id, ""} ->
          case Custyard.Tenants.get_tenant(id) do
            nil ->
              send_resp(conn, 404, "Not found")

            tenant ->
              conn |> put_session(:selected_tenant_id, tenant.id) |> redirect(to: ~p"/operator")
          end

        _ ->
          send_resp(conn, 404, "Not found")
      end
    else
      send_resp(conn, 403, "Forbidden")
    end
  end
end
