defmodule CustyardWeb.Plugs.RequireOperator do
  @moduledoc """
  Plug that requires an authenticated operator session.
  Redirects to login if no operator_id in session, if no operator matches both
  the session's id and its creation-time claim (deleted, or the id reused by a
  newer account; see `CustyardWeb.Live.OperatorAuth.session_operator/2`), or
  if the operator is an admin or agent without an organization
  (`OperatorAccount.orphaned?/1`). Every refusal of a stored session clears it.
  """
  import Plug.Conn
  import Phoenix.Controller

  alias Custyard.OperatorAccount
  alias CustyardWeb.Live.OperatorAuth

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, :operator_id) do
      nil ->
        redirect_to_login(conn, "Please log in")

      operator_id ->
        case OperatorAuth.session_operator(operator_id, get_session(conn, :operator_created)) do
          nil ->
            conn
            |> clear_operator_session()
            |> redirect_to_login("Session expired")

          operator ->
            if OperatorAccount.orphaned?(operator) do
              conn
              |> clear_operator_session()
              |> redirect_to_login(OperatorAuth.no_organization_message())
            else
              assign(conn, :current_operator, operator)
            end
        end
    end
  end

  defp clear_operator_session(conn) do
    conn
    |> delete_session(:operator_id)
    |> delete_session(:operator_created)
  end

  defp redirect_to_login(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: "/operator/login")
    |> halt()
  end
end
