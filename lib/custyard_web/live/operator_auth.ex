defmodule CustyardWeb.Live.OperatorAuth do
  @moduledoc """
  LiveView on_mount hook for operator authentication.
  Ensures operator is logged in and assigns operator_id to socket.
  """
  import Phoenix.LiveView
  import Phoenix.Component

  def on_mount(:default, _params, session, socket) do
    case session["operator_id"] do
      nil ->
        {:halt, redirect(socket, to: "/operator/login")}

      operator_id ->
        {:cont, assign(socket, :operator_id, operator_id)}
    end
  end
end
