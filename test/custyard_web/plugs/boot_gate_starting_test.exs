defmodule CustyardWeb.Plugs.BootGateStartingTest do
  # Custyard.Boot.State lives in :persistent_term, which is global.
  use CustyardWeb.ConnCase, async: false

  alias Custyard.Boot.{Env, State}

  @canary "CANARY-" <> String.duplicate("q", 60)

  @env %{
    "SECRET_KEY_BASE" => @canary,
    "PHX_HOST" => "custyard.example.com",
    "OPERATOR_EMAIL" => "ops-" <> @canary <> "@example.com",
    "LETTERMINT_PROJECT_TOKEN" => "lm_" <> @canary,
    "MAIL_ADAPTER" => "lettermint",
    "DATABASE_PATH" => "/data/custyard.db"
  }

  setup do
    State.reset()
    on_exit(fn -> State.reset() end)

    State.put(%State{
      mode: :starting,
      env: Env.read(@env, config_env: :prod),
      booted_at: ~U[2026-11-03 21:14:08Z]
    })

    :ok
  end

  test "GET / is the starting card, refreshing, uncached, scriptless", %{conn: conn} do
    conn = get(conn, "/")
    body = html_response(conn, 503)

    assert body =~ "Custyard is starting"
    assert body =~ ~s(data-testid="boot-card-starting")
    assert body =~ "Checking the database and applying any pending migrations."
    assert body =~ "This page refreshes itself."
    assert body =~ ~s(http-equiv="refresh" content="3")
    assert body =~ ~s(data-testid="boot-ground-truth")
    assert body =~ "2026-11-03 21:14:08 UTC"
    assert body =~ "SQLite file at /data/custyard.db"
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    refute body =~ "<script"
    refute body =~ @canary
    refute body =~ "ops-"
    assert conn.halted
  end

  test "every other page is the starting card too", %{conn: conn} do
    body = html_response(get(conn, "/operator/login"), 503)
    assert body =~ ~s(data-testid="boot-card-starting")
    refute body =~ @canary
  end

  test "liveness is 200 and readiness reports starting", %{conn: conn} do
    assert json_response(get(conn, "/api/health/live"), 200) == %{"status" => "live"}

    assert json_response(get(build_conn(), "/api/health"), 503) == %{
             "status" => "starting",
             "mode" => "starting"
           }
  end

  test "other API paths get a 503 JSON verdict and halt", %{conn: conn} do
    conn = post(conn, "/api/webhook/route/x", %{"any" => "thing"})

    assert json_response(conn, 503) == %{"status" => "starting"}
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert conn.halted
  end

  test "static assets are still served", %{conn: conn} do
    conn = get(conn, "/robots.txt")
    assert conn.status == 200
    refute conn.resp_body =~ "Custyard is starting"
  end
end
