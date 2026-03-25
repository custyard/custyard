defmodule CustyardWeb.Plugs.RequireOperator do
  @moduledoc """
  Plug that requires an authenticated operator session.
  Redirects to login if no operator_id in session or if operator no longer exists.
  """
  import Plug.Conn
  import Phoenix.Controller

  alias Custyard.{OperatorAccount, Repo}

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_session(conn, :operator_id) do
      nil ->
        redirect_to_login(conn, "Please log in")

      operator_id ->
        case Repo.get(OperatorAccount, operator_id) do
          nil ->
            conn
            |> delete_session(:operator_id)
            |> redirect_to_login("Session expired")

          operator ->
            assign(conn, :current_operator, operator)
        end
    end
  end

  defp redirect_to_login(conn, message) do
    conn
    |> put_flash(:error, message)
    |> redirect(to: "/operator/login")
    |> halt()
  end
end
