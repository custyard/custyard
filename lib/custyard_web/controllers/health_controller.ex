defmodule CustyardWeb.HealthController do
  use CustyardWeb, :controller

  def index(conn, _params) do
    json(conn, %{status: "ok"})
  end
end
