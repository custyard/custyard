defmodule CustyardWeb.Live.OperatorAuth do
  @moduledoc """
  LiveView on_mount hook for operator authentication.
  Ensures operator is logged in and assigns operator and scoping info to socket.
  """
  import Phoenix.LiveView
  import Phoenix.Component

  alias Custyard.{OperatorAccount, Repo}

  def on_mount(:default, _params, session, socket) do
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
             |> assign(:scoped_organization_id, OperatorAccount.scoped_organization_id(operator))}
        end
    end
  end
end
