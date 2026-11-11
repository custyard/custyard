defmodule CustyardWeb.Plugs.BootGateTest do
  # Custyard.Boot.State lives in :persistent_term, which is global.
  use CustyardWeb.ConnCase, async: false

  alias Custyard.Boot.{Env, State}

  @canary "CANARY-" <> String.duplicate("q", 60)

  @partial_env %{
    "SECRET_KEY_BASE" => @canary,
    "OPERATOR_EMAIL" => "ops-" <> @canary <> "@example.com",
    "LETTERMINT_PROJECT_TOKEN" => "lm_" <> @canary,
    "MAIL_ADAPTOR" => "lettermint",
    "CREDENTIAL_ENCRYPTION_KEY" => "\"" <> @canary <> "\""
  }

  setup do
    State.reset()
    on_exit(fn -> State.reset() end)
    :ok
  end

  defp set_mode(mode, extra \\ %{}) do
    State.update(fn state ->
      Map.merge(%{state | mode: mode, booted_at: ~U[2026-11-03 21:14:08Z]}, extra)
    end)
  end

  defp unconfigured(env_map \\ @partial_env) do
    set_mode(:unconfigured, %{env: Env.read(env_map, config_env: :prod)})
  end

  defp database_unavailable(category, overrides \\ %{}) do
    env = Env.read(%{}, config_env: :prod)

    database =
      Map.merge(
        %{
          status: :error,
          category: category,
          detail: nil,
          attempts: 6,
          last_attempt_at: DateTime.add(DateTime.utc_now(), -4, :second),
          retry_every_ms: 10_000,
          facts: %{kind: :sqlite, path: "/data/custyard.db", mounted?: true, file_exists?: false}
        },
        overrides
      )

    set_mode(:database_unavailable, %{env: env, database: database})
  end

  describe ":unconfigured" do
    test "renders the doctor card with problem names and never a value", %{conn: conn} do
      unconfigured()
      conn = get(conn, "/")
      body = html_response(conn, 503)

      assert body =~ "Custyard is not configured yet"
      assert body =~ ~s(data-testid="boot-card-unconfigured")
      # Missing required names and the quoted key are listed...
      assert body =~ "PHX_HOST"
      assert body =~ "MAIL_ADAPTER"
      assert body =~ "CREDENTIAL_ENCRYPTION_KEY"
      assert body =~ "wrapped in quote characters"
      # ...and the near miss is named.
      assert body =~ "MAIL_ADAPTOR (did you mean MAIL_ADAPTER)"
      # Ground truth: counts, present names, image, boot time.
      assert body =~ "5 variables visible · 4 of them Custyard settings"
      assert body =~ "LETTERMINT_PROJECT_TOKEN"
      assert body =~ "Booted"
      assert body =~ "2026-11-03 21:14:08 UTC"
      assert body =~ "custyard "
      assert body =~ "SQLite file at /data/custyard.db"
      # Paste block generates a fresh secret only for what is missing or
      # malformed: the quoted key gets a replacement, the valid base does not.
      assert body =~ ~s(data-testid="boot-paste-block")
      assert body =~ "PHX_HOST=‹custyard.example.com›"
      refute body =~ "SECRET_KEY_BASE="
      assert body =~ "CREDENTIAL_ENCRYPTION_KEY="
      assert body =~ "MAIL_ADAPTER=lettermint"
      # Nothing from the environment's values leaks.
      refute body =~ @canary
      refute body =~ "ops-"
      # Unconfigured is static until a restart: no meta refresh.
      refute body =~ "http-equiv"
      # No scripts, no session.
      refute body =~ "<script"
      refute body =~ "csrf"
      assert get_resp_header(conn, "cache-control") == ["no-store"]
      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "default-src 'self'"
    end

    test "with zero variables the paste block has every required line", %{conn: conn} do
      unconfigured(%{})
      body = html_response(get(conn, "/operator/login"), 503)

      assert body =~ "SECRET_KEY_BASE="
      assert body =~ "CREDENTIAL_ENCRYPTION_KEY="
      assert body =~ "PHX_HOST=‹custyard.example.com›"
      assert body =~ "OPERATOR_EMAIL=‹you@example.com›"
      assert body =~ "LETTERMINT_PROJECT_TOKEN=‹project token›"
      assert body =~ "0 variables visible · 0 of them Custyard settings"
      assert body =~ "Docker:"
    end

    test "picks the platform hint from the environment", %{conn: conn} do
      unconfigured(%{"FLY_APP_NAME" => "custyard-prod"})
      assert html_response(get(conn, "/"), 503) =~ "fly secrets set"

      unconfigured(%{
        "BUNNY_DATABASE_URL" => "https://x.lite.bunnydb.net",
        "BUNNY_DATABASE_AUTH_TOKEN" => "t"
      })

      body = html_response(get(build_conn(), "/"), 503)
      assert body =~ "Magic Container"
      assert body =~ "Bunny Database / libSQL over HTTPS"
      refute body =~ "x.lite.bunnydb.net"

      unconfigured(%{"DATABASE_URL" => "libsql://x.turso.io", "TURSO_AUTH_TOKEN" => "t"})
      body = html_response(get(build_conn(), "/"), 503)
      assert body =~ "Turso / libSQL over HTTPS"
      refute body =~ "x.turso.io"
    end

    test "health paths pass through to the controller", %{conn: conn} do
      unconfigured()

      assert json_response(get(conn, "/api/health/live"), 200) == %{"status" => "live"}
      assert json_response(get(build_conn(), "/api/health/live/"), 200) == %{"status" => "live"}

      assert json_response(get(build_conn(), "/api/health"), 503) == %{
               "status" => "setup_required",
               "mode" => "unconfigured"
             }
    end

    test "other API paths get a 503 JSON verdict", %{conn: conn} do
      unconfigured()

      conn = post(conn, "/api/webhook/route/some-token", %{"any" => "thing"})

      assert json_response(conn, 503) == %{"status" => "setup_required"}
      assert conn.halted
    end

    test "static assets are still served", %{conn: conn} do
      unconfigured()
      conn = get(conn, "/robots.txt")
      assert conn.status == 200
      refute conn.resp_body =~ "Custyard is not configured yet"
    end
  end

  describe ":database_unavailable" do
    test "renders the category, detail, retry line and facts", %{conn: conn} do
      database_unavailable(:auth_rejected, %{detail: "HTTP 401 from the libSQL server"})
      body = html_response(get(conn, "/"), 503)

      assert body =~ "Custyard cannot reach its database"
      assert body =~ "authentication rejected"
      assert body =~ "HTTP 401 from the libSQL server"
      assert body =~ "Last attempt"
      assert body =~ ~r/\d+ s ago/
      assert body =~ "retrying every 10 s"
      assert body =~ "6 attempts"
      assert body =~ "TURSO_AUTH_TOKEN was created for this database"
      assert body =~ "restarts into normal mode on its own"
      assert body =~ ~s(http-equiv="refresh" content="5")
      assert body =~ "/data is a mount"
      assert body =~ "file does not exist yet"
    end

    test "each category has its own label", %{conn: conn} do
      for {category, label} <- [
            {:unreachable, "cannot connect"},
            {:not_writable, "database path is not writable"},
            {:locked, "database file is locked"},
            {:volume_missing, "no volume mounted at /data"},
            {:unknown, "connection failed"}
          ] do
        database_unavailable(category)
        assert html_response(get(conn, "/"), 503) =~ label
      end
    end

    test "a failed migration never promises a retry", %{conn: conn} do
      database_unavailable(:migration_failed, %{detail: "20261103000000_add_things"})
      body = html_response(get(conn, "/"), 503)

      assert body =~ "a migration failed"
      assert body =~ "20261103000000_add_things"
      assert body =~ "restart after fixing the migration"
      refute body =~ "retrying every"
      refute body =~ "restarts into normal mode on its own"
      assert body =~ "does not restart on its own"
    end

    test "API and health behave as in the unconfigured tier", %{conn: conn} do
      database_unavailable(:unreachable)

      assert json_response(get(conn, "/api/health"), 503) == %{
               "status" => "database_unavailable",
               "mode" => "database_unavailable"
             }

      assert json_response(get(build_conn(), "/api/health/live"), 200) == %{"status" => "live"}

      assert json_response(post(build_conn(), "/api/webhook/route/x"), 503) == %{
               "status" => "database_unavailable"
             }
    end
  end

  describe ":first_run" do
    setup do
      set_mode(:first_run)
      State.put_step(:schema, :ok, "41 migrations applied in 2.1 s")
      State.put_step(:operator, :skipped, "OPERATOR_EMAIL is not set")
      State.put_step(:mail, :failed, "lettermint rejected the message (422: sender not verified)")
      :ok
    end

    test "rewrites GET / to the setup card", %{conn: conn} do
      conn = get(conn, "/")
      body = html_response(conn, 200)

      assert body =~ "Setting up Custyard"
      assert body =~ "Database schema"
      assert body =~ "41 migrations applied in 2.1 s"
      assert body =~ "bin/operator add you@example.com"
      assert body =~ "Login links will fail the same way"
      assert body =~ "422: sender not verified"
      assert body =~ "This page refreshes itself."
      assert body =~ ~s(http-equiv="refresh" content="5")
      refute body =~ "Sign in at"
      assert conn.halted
    end

    test "shows the sign-in link once complete", %{conn: conn} do
      State.update(fn state ->
        %{
          state
          | first_run: %{
              state.first_run
              | completed_at: DateTime.utc_now(),
                operator_email: "you@example.com"
            }
        }
      end)

      State.put_step(:operator, :ok, "you@example.com (super_admin), from OPERATOR_EMAIL")
      State.put_step(:mail, :ok, "welcome mail accepted by lettermint")
      State.put_step(:sign_in, :pending)

      body = html_response(get(conn, "/"), 200)
      assert body =~ ~s(href="/operator/login")
      assert body =~ "you@example.com"
      assert body =~ "remove <code>OPERATOR_EMAIL</code>"
    end

    test "everything else is the live app", %{conn: conn} do
      conn = get(conn, "/operator/login")

      assert html_response(conn, 200) =~ "Operator Login"
      refute conn.resp_body =~ "Setting up Custyard"

      assert json_response(get(build_conn(), "/api/health/live"), 200) == %{"status" => "live"}
      health = get(build_conn(), "/api/health")
      assert health.status in [200, 503]
      assert json_response(health, health.status)["checks"]["database"] == "ok"
    end

    test "only GET / is rewritten", %{conn: conn} do
      conn = post(conn, "/", %{})
      assert conn.status == 404
      refute conn.resp_body =~ "Setting up Custyard"
    end
  end

  describe ":ready" do
    test "passes every request through untouched", %{conn: conn} do
      assert State.mode() == :ready

      conn = get(conn, "/")
      assert conn.status == 200
      refute conn.resp_body =~ "Setting up Custyard"
      refute conn.resp_body =~ "Custyard is not configured yet"
    end

    test "keeps the finished checklist on GET / for the boot that completed first run",
         %{conn: conn} do
      State.update(fn state ->
        %{
          state
          | first_run: %{
              state.first_run
              | completed_at: DateTime.utc_now(),
                operator_email: "you@example.com"
            }
        }
      end)

      State.put_step(:sign_in, :ok, "an operator can sign in")

      body = html_response(get(conn, "/"), 200)
      assert body =~ "Setting up Custyard"
      assert body =~ ~s(href="/operator/login")

      assert html_response(get(build_conn(), "/operator/login"), 200) =~ "Operator Login"
    end
  end
end
