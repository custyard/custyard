defmodule CustyardWeb.Live.InstanceAdminAuth do
  @moduledoc "Installation-only authentication with no implicit staff authority."
  import Phoenix.Component
  import Phoenix.LiveView
  alias Custyard.{Auth.Account, InstanceAdmin, Repo, Tenants}

  def on_mount(:default, _, session, socket) do
    socket = CustyardWeb.HostScope.capture(socket)

    with true <- socket.assigns.verified_host == Tenants.normalize_host(Tenants.app_host()),
         id when not is_nil(id) <- session["instance_admin_id"],
         %InstanceAdmin{} = admin <- Repo.get(InstanceAdmin, id),
         true <- Account.session_claim_matches?(admin, session["instance_admin_claim"]) do
      {:cont,
       socket
       |> assign(:current_instance_admin, admin)
       |> attach_hook(:refresh_admin, :handle_event, fn _, _, socket ->
         refresh(socket, admin)
       end)
       |> attach_hook(:refresh_admin_params, :handle_params, fn _, _, socket ->
         refresh(socket, admin)
       end)
       |> attach_hook(:refresh_admin_info, :handle_info, fn _, socket ->
         refresh(socket, admin)
       end)
       |> attach_hook(:refresh_admin_async, :handle_async, fn _, _, socket ->
         refresh(socket, admin)
       end)}
    else
      _ -> {:halt, redirect(socket, to: "/admin/login")}
    end
  end

  defp refresh(socket, admin) do
    current = Repo.get(InstanceAdmin, admin.id)

    if Account.session_claim_matches?(current, admin.session_claim),
      do: {:cont, assign(socket, :current_instance_admin, current)},
      else: {:halt, redirect(socket, to: "/admin/login")}
  end
end
