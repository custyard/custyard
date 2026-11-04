defmodule CustyardWeb.HealthControllerTest do
  # Custyard.Boot.State lives in :persistent_term, which is global.
  use CustyardWeb.ConnCase, async: false

  alias Custyard.Boot.State

  setup do
    State.reset()
    on_exit(fn -> State.reset() end)
    :ok
  end

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

  test "GET /api/health/live is 200 with no checks", %{conn: conn} do
    conn = get(conn, ~p"/api/health/live")

    assert json_response(conn, 200) == %{"status" => "live"}
  end

  test "GET /api/health in first-run mode still runs the checks", %{conn: conn} do
    State.update(&%{&1 | mode: :first_run})
    conn = get(conn, ~p"/api/health")

    assert json_response(conn, conn.status)["checks"]["database"] == "ok"
  end

  test "GET /api/health answers the verdict in doctor modes without the Repo", %{conn: conn} do
    State.update(&%{&1 | mode: :unconfigured})

    assert json_response(get(conn, ~p"/api/health"), 503) == %{
             "status" => "setup_required",
             "mode" => "unconfigured"
           }

    State.update(&%{&1 | mode: :starting})

    assert json_response(get(build_conn(), ~p"/api/health"), 503) == %{
             "status" => "starting",
             "mode" => "starting"
           }

    State.update(&%{&1 | mode: :database_unavailable})

    assert json_response(get(build_conn(), ~p"/api/health"), 503) == %{
             "status" => "database_unavailable",
             "mode" => "database_unavailable"
           }

    assert json_response(get(build_conn(), ~p"/api/health/live"), 200) == %{"status" => "live"}
  end
end
