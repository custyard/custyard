defmodule CustyardWeb.Live.OperatorAuth do
  @moduledoc """
  LiveView on_mount hook for operator authentication and role-based authorization.

  Supports three mount modes:
  - `:default` - any authenticated operator
  - `:require_admin` - admin or super_admin only
  - `:require_super_admin` - super_admin only

  All modes assign `:current_operator`, `:scoped_organization_id`,
  `:current_role`, and `:is_super_admin` to the socket.
  """
  import Phoenix.LiveView
  import Phoenix.Component

  alias Custyard.{Authorization, OperatorAccount, Repo}

  def on_mount(:default, _params, session, socket) do
    authenticate(session, socket)
  end

  def on_mount(:require_admin, _params, session, socket) do
    authorize_role(session, socket, "admin")
  end

  def on_mount(:require_super_admin, _params, session, socket) do
    authorize_role(session, socket, "super_admin")
  end

  defp authorize_role(session, socket, required_role) do
    with {:cont, socket} <- authenticate(session, socket) do
      if Authorization.has_minimum_role?(socket.assigns.current_operator, required_role) do
        {:cont, socket}
      else
        {:halt,
         socket
         |> put_flash(:error, "Insufficient permissions")
         |> redirect(to: "/operator")}
      end
    end
  end

  defp authenticate(session, socket) do
    case session["operator_id"] do
      nil ->
        {:halt, redirect(socket, to: "/operator/login")}

      operator_id ->
        case Repo.get(OperatorAccount, operator_id) do
          nil ->
            {:halt, redirect(socket, to: "/operator/login")}

          operator ->
            {:cont,
             socket
             |> assign(:operator_id, operator_id)
             |> assign_operator(operator)
             |> attach_refresh_hooks()}
        end
    end
  end

  defp assign_operator(socket, operator) do
    socket
    |> assign(:current_operator, operator)
    |> assign(:scoped_organization_id, OperatorAccount.scoped_organization_id(operator))
    |> assign(:current_role, operator.role)
    |> assign(:is_super_admin, operator.role == "super_admin")
  end

  defp attach_refresh_hooks(socket) do
    socket
    |> attach_hook(:refresh_operator_event, :handle_event, fn _event, _params, socket ->
      refresh_operator(socket)
    end)
    |> attach_hook(:refresh_operator_info, :handle_info, fn _message, socket ->
      refresh_operator(socket)
    end)
    |> attach_hook(:refresh_operator_params, :handle_params, fn _params, _uri, socket ->
      refresh_operator(socket)
    end)
    |> attach_hook(:refresh_operator_async, :handle_async, fn _name, _result, socket ->
      refresh_operator(socket)
    end)
  end

  defp refresh_operator(socket) do
    case Repo.get(OperatorAccount, socket.assigns.operator_id) do
      nil ->
        {:halt, redirect(socket, to: "/operator/login")}

      operator ->
        previous = socket.assigns.current_operator

        if operator.role == previous.role and operator.organization_id == previous.organization_id do
          {:cont, assign_operator(socket, operator)}
        else
          # Remount under the new role and organization before any existing
          # view can render or act on resources loaded under the old scope.
          {:halt, redirect(socket, to: "/operator")}
        end
    end
  end
end
