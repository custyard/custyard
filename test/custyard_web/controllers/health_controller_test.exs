defmodule CustyardWeb.HealthControllerTest do
  use CustyardWeb.ConnCase, async: true

  test "GET /api/health returns ok", %{conn: conn} do
    response =
      conn
      |> get(~p"/api/health")
      |> json_response(200)

    assert response == %{"status" => "ok"}
  end
end
