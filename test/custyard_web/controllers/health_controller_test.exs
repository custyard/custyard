defmodule CustyardWeb.HealthControllerTest do
  use CustyardWeb.ConnCase, async: true

  test "GET /api/health returns ok", %{conn: conn} do
    conn = get(conn, ~p"/api/health")
    assert json_response(conn, 200) == %{"status" => "ok"}
  end
end
