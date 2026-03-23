defmodule CustyardWeb.Plugs.RequireOperator do
  @moduledoc """
  Plug that requires an authenticated operator session.
  Redirects to login if no operator_id in session.
  """
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    if get_session(conn, :operator_id) do
      conn
    else
      conn
      |> put_flash(:error, "Please log in")
      |> redirect(to: "/operator/login")
      |> halt()
    end
  end
end
