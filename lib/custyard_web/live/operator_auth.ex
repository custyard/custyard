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
    with {:cont, socket} <- authenticate(session, socket) do
      if Authorization.has_minimum_role?(socket.assigns.current_operator, "admin") do
        {:cont, socket}
      else
        {:halt,
         socket
         |> put_flash(:error, "Insufficient permissions")
         |> redirect(to: "/operator")}
      end
    end
  end

  def on_mount(:require_super_admin, _params, session, socket) do
    with {:cont, socket} <- authenticate(session, socket) do
      if Authorization.has_minimum_role?(socket.assigns.current_operator, "super_admin") do
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
             |> assign(:current_operator, operator)
             |> assign(:scoped_organization_id, OperatorAccount.scoped_organization_id(operator))
             |> assign(:current_role, operator.role)
             |> assign(:is_super_admin, operator.role == "super_admin")}
        end
    end
  end
end
