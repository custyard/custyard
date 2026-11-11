defmodule CustyardWeb.Admin.SystemControllerTest do
  # Custyard.Boot.State lives in :persistent_term, which is global.
  use CustyardWeb.ConnCase, async: false

  import Custyard.Factory

  alias Custyard.Boot.{Env, State}
  alias Custyard.InstanceAdmins

  # /admin is served on the installation host only.
  @moduletag :explicit_tenant_hosts

  @canary "CANARY-" <> String.duplicate("s", 60)

  setup do
    State.reset()
    on_exit(fn -> State.reset() end)
    :ok
  end

  defp instance_admin(email \\ "ops@example.com") do
    {:created, admin} = InstanceAdmins.create_admin(email)
    admin
  end

  defp log_in(conn, admin) do
    Phoenix.ConnTest.init_test_session(conn, %{
      instance_admin_id: admin.id,
      instance_admin_claim: admin.session_claim
    })
  end

  test "requires an instance administrator session", %{conn: conn} do
    conn = get(conn, ~p"/admin/system")
    assert redirected_to(conn) == "/admin/login"
  end

  test "refuses a stale session claim", %{conn: conn} do
    admin = instance_admin()

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{
        instance_admin_id: admin.id,
        instance_admin_claim: "stale-claim"
      })
      |> get(~p"/admin/system")

    assert redirected_to(conn) == "/admin/login"
  end

  test "tenant staff cannot reach it, with or without a staff session" do
    tenant = insert_tenant()
    {:ok, _} = Custyard.Tenants.add_host(tenant.id, "workspace.example.com")
    staff = insert_staff_account(role: "admin", tenant_id: tenant.id)

    conn =
      %{Phoenix.ConnTest.build_conn() | host: "workspace.example.com"}
      |> Phoenix.ConnTest.init_test_session(%{})
      |> put_staff_session(staff)
      |> get("/admin/system")

    assert conn.status == 404

    # The staff session carries no installation authority on the installation host either.
    conn =
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.init_test_session(%{})
      |> put_staff_session(staff)
      |> Map.put(:host, Custyard.Tenants.app_host())
      |> get("/admin/system")

    assert redirected_to(conn) == "/admin/login"
  end

  test "renders mode, steps, last mail, facts and warnings without values", %{conn: conn} do
    admin = instance_admin()

    env =
      Env.read(
        %{
          "SECRET_KEY_BASE" => @canary,
          "CREDENTIAL_ENCRYPTION_KEY" => Base.encode64(:crypto.strong_rand_bytes(32)),
          "PHX_HOST" => "custyard.example.com",
          "MAIL_ADAPTER" => "lettermint",
          "LETTERMINT_PROJECT_TOKEN" => "lm_" <> @canary,
          "LETTERMINT_TEAM_TOKEN" => "team_" <> @canary,
          "INSTANCE_ADMIN_EMAIL" => "ops@example.com"
        },
        config_env: :prod
      )

    State.update(fn state ->
      %{
        state
        | mode: :ready,
          env: env,
          booted_at: ~U[2026-11-03 21:14:08Z],
          last_mail: %{
            at: ~U[2026-11-03 21:15:00Z],
            adapter: :lettermint,
            status: :error,
            detail: "422: sender address not verified"
          },
          database: %{state.database | facts: %{kind: :sqlite, path: "/data/custyard.db"}}
      }
    end)

    State.put_step(:schema, :ok, "41 migrations applied in 2.1 s")
    State.put_step(:instance_admin, :ok, "ops@example.com, from INSTANCE_ADMIN_EMAIL")

    body = conn |> log_in(admin) |> get(~p"/admin/system") |> html_response(200)

    assert body =~ ~s(data-testid="admin-system-page")
    assert body =~ ~r/data-testid="system-mode"[^>]*>\s*ready\s*</
    assert body =~ "Database schema"
    assert body =~ "41 migrations applied in 2.1 s"
    assert body =~ "Instance administrator"
    assert body =~ "2026-11-03 21:14:08 UTC"
    assert body =~ "2026-11-03 21:15:00 UTC"
    assert body =~ "lettermint"
    assert body =~ "422: sender address not verified"
    # Warnings from the env, by name.
    assert body =~ "LETTERMINT_TEAM_TOKEN"
    assert body =~ "no longer read"
    # Database facts: probe facts plus live counts.
    assert body =~ "SQLite file at /data/custyard.db"
    assert body =~ ~r/\d+ migrations/
    assert body =~ ~r/\d+ instance administrators?/
    # Never a value.
    refute body =~ @canary
    # Linked from the instance console navigation.
    assert body =~ ~s(data-testid="instance-admin-system-link")
  end

  test "renders with the default state when nothing was recorded", %{conn: conn} do
    admin = instance_admin()
    body = conn |> log_in(admin) |> get(~p"/admin/system") |> html_response(200)

    assert body =~ "No boot report was recorded for this process."
    assert body =~ "No mail has been sent since boot."
    assert body =~ "unknown"
  end
end
