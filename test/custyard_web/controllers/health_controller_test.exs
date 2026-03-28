defmodule CustyardWeb.HealthControllerTest do
  use CustyardWeb.ConnCase, async: true

  test "GET /api/health returns status", %{conn: conn} do
    conn = get(conn, ~p"/api/health")

    # Health endpoint may return 200 (all ok) or 503 (some checks failed)
    # In test env, scheduler may not be running
    assert conn.status in [200, 503]
    response = json_response(conn, conn.status)

    assert response["status"] in ["ok", "error"]
    assert is_map(response["checks"])
    assert response["checks"]["database"] == "ok"
  end
end
