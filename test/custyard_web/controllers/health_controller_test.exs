defmodule CustyardWeb.HealthControllerTest do
  use CustyardWeb.ConnCase

  test "GET /health returns 200 with ok status", %{conn: conn} do
    conn = get(conn, "/health")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end
end
