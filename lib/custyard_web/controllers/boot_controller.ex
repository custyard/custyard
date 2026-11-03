defmodule CustyardWeb.BootController do
  @moduledoc """
  Renders the doctor and first-run cards for `CustyardWeb.Plugs.BootGate`.

  Called directly by the gate (`call(conn, action)`), not through the router,
  because the gate runs before `Plug.Parsers` and `Plug.Session`: the format
  is forced to HTML here, the root layout is `boot_root`, there is no app
  layout, and nothing reads params, the session or the Repo. Everything
  comes from `Custyard.Boot.State`.

  Doctor cards answer 503 so uptime checkers see the instance is not serving;
  the first-run card is a 200 because the application is up.
  """

  use CustyardWeb, :controller

  alias Custyard.Boot.{Report, State}

  # No scripts are loaded, so script-src is omitted (default-src covers it).
  @csp "default-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'"

  plug :put_format, "html"
  plug :put_root_layout, html: {CustyardWeb.Layouts, :boot_root}
  plug :put_layout, false
  plug :put_secure_browser_headers, %{"content-security-policy" => @csp}
  plug :no_store

  @doc "Environment problems; nothing changes without a restart, so no refresh."
  def unconfigured(conn, _params) do
    state = State.get()
    env = state.env

    conn
    |> put_status(503)
    |> render(:unconfigured,
      page_title: "Custyard is not configured yet",
      state: state,
      env: env,
      paste_block: env && Report.paste_block(env),
      platform: (env && env.settings[:platform]) || :unknown
    )
  end

  @doc "Database probe failed; refreshes while Boot.Monitor retries."
  def database_unavailable(conn, _params) do
    state = State.get()

    conn
    |> put_status(503)
    |> render(:database_unavailable,
      page_title: "Custyard cannot reach its database",
      refresh: 5,
      state: state,
      db: state.database,
      migration_failed?: state.database.category == :migration_failed
    )
  end

  @doc "First start on an empty database; refreshes while Boot.FirstRun works."
  def first_run(conn, _params) do
    state = State.get()

    render(conn, :first_run,
      page_title: "Setting up Custyard",
      refresh: 5,
      state: state,
      first_run: state.first_run
    )
  end

  defp no_store(conn, _opts), do: put_resp_header(conn, "cache-control", "no-store")
end
