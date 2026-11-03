defmodule CustyardWeb.Operator.SystemControllerTest do
  # Custyard.Boot.State lives in :persistent_term, which is global.
  use CustyardWeb.ConnCase, async: false

  import Custyard.Factory

  alias Custyard.Boot.{Env, State}

  @canary "CANARY-" <> String.duplicate("s", 60)

  setup do
    State.reset()
    on_exit(fn -> State.reset() end)
    :ok
  end

  defp log_in(conn, operator) do
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> put_operator_session(operator)
  end

  test "requires an operator session", %{conn: conn} do
    conn = get(conn, ~p"/operator/system")
    assert redirected_to(conn) == "/operator/login"
  end

  test "refuses an organization admin", %{conn: conn} do
    admin = insert_operator_account(%{role: "admin"})
    conn = conn |> log_in(admin) |> get(~p"/operator/system")
    assert redirected_to(conn) == "/operator"
  end

  test "renders mode, steps, last mail, facts and warnings without values", %{conn: conn} do
    operator = insert_operator_account()

    env =
      Env.read(
        %{
          "SECRET_KEY_BASE" => @canary,
          "PHX_HOST" => "custyard.example.com",
          "MAIL_ADAPTER" => "lettermint",
          "LETTERMINT_API_KEY" => "lm_" <> @canary,
          "OPERATOR_EMAIL" => "ops@example.com"
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
    State.put_step(:operator, :ok, "ops@example.com (super_admin), from OPERATOR_EMAIL")

    body = conn |> log_in(operator) |> get(~p"/operator/system") |> html_response(200)

    assert body =~ ~s(data-testid="operator-system-page")
    assert body =~ ~r/data-testid="system-mode"[^>]*>\s*ready\s*</
    assert body =~ "Database schema"
    assert body =~ "41 migrations applied in 2.1 s"
    assert body =~ "Operator account"
    assert body =~ "2026-11-03 21:14:08 UTC"
    assert body =~ "2026-11-03 21:15:00 UTC"
    assert body =~ "lettermint"
    assert body =~ "422: sender address not verified"
    # Warnings from the env, by name.
    assert body =~ "LETTERMINT_API_KEY"
    assert body =~ "deprecated name"
    assert body =~ "CREDENTIAL_ENCRYPTION_KEY"
    # Database facts: probe facts plus live counts.
    assert body =~ "SQLite file at /data/custyard.db"
    assert body =~ ~r/\d+ migrations/
    assert body =~ ~r/\d+ operator accounts?/
    # Never a value.
    refute body =~ @canary
    # Linked from the operator navigation.
    assert body =~ ~s(data-testid="operator-nav-system")
  end

  test "renders with the default state when nothing was recorded", %{conn: conn} do
    operator = insert_operator_account()
    body = conn |> log_in(operator) |> get(~p"/operator/system") |> html_response(200)

    assert body =~ "No boot report was recorded for this process."
    assert body =~ "No mail has been sent since boot."
    assert body =~ "unknown"
  end
end
