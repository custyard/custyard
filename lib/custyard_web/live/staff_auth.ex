defmodule CustyardWeb.Live.StaffAuth do
  @moduledoc "Authenticates tenant staff against the actual LiveView host on every event."
  import Phoenix.LiveView
  import Phoenix.Component
  alias Custyard.{Auth.Account, Authorization, StaffAccount, Repo, Scope, Tenants}
  def no_organization_message, do: "Workspace access unavailable; ask your tenant administrator."

  def session_staff(id, claim) do
    with id when not is_nil(id) <- id,
         %StaffAccount{} = staff <- Repo.get(StaffAccount, id),
         true <- Account.session_claim_matches?(staff, claim),
         true <- Tenants.active?(staff.tenant_id),
         do: staff,
         else: (_ -> nil)
  end

  def on_mount(mode, _params, session, socket) do
    socket = CustyardWeb.HostScope.capture(socket)
    tenant = Tenants.resolve_host(socket.assigns.verified_host)
    staff = session_staff(session["staff_id"], session["staff_claim"])
    scope = staff && Scope.for_staff(staff, tenant)

    cond do
      is_nil(scope) ->
        {:halt, redirect(socket, to: "/app/login")}

      mode == :require_admin and not Authorization.has_minimum_role?(staff, "admin") ->
        {:halt, redirect(socket, to: "/app")}

      true ->
        {:cont,
         socket
         |> assign(:staff_id, staff.id)
         |> assign(:staff_session_claim, staff.session_claim)
         |> assign(:current_tenant, tenant)
         |> assign_staff(staff, scope)
         |> hooks()}
    end
  end

  defp assign_staff(socket, staff, scope) do
    socket
    |> assign(:current_staff, staff)
    |> assign(:current_scope, scope)
    |> assign(:current_role, staff.role)
    |> assign(:site_name, socket.assigns.current_tenant.name)
  end

  defp hooks(socket) do
    socket
    |> attach_hook(:refresh_staff_event, :handle_event, fn _, _, socket -> refresh(socket) end)
    |> attach_hook(:refresh_staff_info, :handle_info, fn _, socket -> refresh(socket) end)
    |> attach_hook(:refresh_staff_params, :handle_params, fn _, _, socket -> refresh(socket) end)
    |> attach_hook(:refresh_staff_async, :handle_async, fn _, _, socket -> refresh(socket) end)
  end

  defp refresh(socket) do
    with staff when not is_nil(staff) <-
           session_staff(socket.assigns.staff_id, socket.assigns.staff_session_claim),
         tenant when not is_nil(tenant) <- Tenants.resolve_host(socket.assigns.verified_host),
         %Scope{} = scope <- Scope.for_staff(staff, tenant),
         true <- staff.role == socket.assigns.current_role do
      {:cont, socket |> assign(:current_tenant, tenant) |> assign_staff(staff, scope)}
    else
      _ -> {:halt, redirect(socket, to: "/app/login")}
    end
  end
end
