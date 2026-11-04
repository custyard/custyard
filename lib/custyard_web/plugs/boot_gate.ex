defmodule CustyardWeb.Plugs.BootGate do
  @moduledoc """
  Serves the boot verdict instead of the app while the app cannot run
  (docs/backlog/1103-first-run-experience.md).

  Sits in the endpoint right after `Plug.Static`, before anything that could
  touch the Repo or the session. One `:persistent_term` read per request in
  the normal case.

  | mode                     | `/api/health*` | other `/api/*` | `GET /`        | everything else |
  |--------------------------|----------------|----------------|----------------|-----------------|
  | `:ready`                 | pass           | pass           | pass (*)       | pass            |
  | `:first_run`             | pass           | pass           | first-run card | pass            |
  | `:unconfigured`          | pass           | 503 JSON       | doctor card    | doctor card     |
  | `:database_unavailable`  | pass           | 503 JSON       | doctor card    | doctor card     |

  The health controller answers readiness itself in doctor modes without the
  Repo; the liveness path keeps platform checks green so the card stays up.

  (*) When this boot completed the first run (`first_run.completed_at` is
  set), `GET /` keeps showing the finished checklist until the next restart,
  so the operator who set `OPERATOR_EMAIL` sees what happened and where to
  sign in instead of an unexplained landing page. The state is not persisted,
  so the next boot serves the landing page as usual.
  """

  @behaviour Plug

  import Plug.Conn

  alias Custyard.Boot.State
  alias CustyardWeb.BootController

  @health_paths ["/api/health", "/api/health/live"]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    case State.mode() do
      :ready -> completed_first_run(conn)
      :first_run -> first_run(conn)
      :unconfigured -> doctor(conn, :unconfigured, "setup_required")
      :database_unavailable -> doctor(conn, :database_unavailable, "database_unavailable")
    end
  end

  defp first_run(%Plug.Conn{method: "GET", path_info: []} = conn) do
    conn |> BootController.call(:first_run) |> halt()
  end

  defp first_run(conn), do: conn

  defp completed_first_run(%Plug.Conn{method: "GET", path_info: []} = conn) do
    if State.get().first_run.completed_at, do: first_run(conn), else: conn
  end

  defp completed_first_run(conn), do: conn

  defp doctor(%Plug.Conn{request_path: path} = conn, _action, _status)
       when path in @health_paths do
    conn
  end

  defp doctor(%Plug.Conn{request_path: "/api/" <> _} = conn, _action, status) do
    body = Phoenix.json_library().encode_to_iodata!(%{status: status})

    conn
    |> put_resp_content_type("application/json")
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(503, body)
    |> halt()
  end

  defp doctor(conn, action, _status) do
    conn |> BootController.call(action) |> halt()
  end
end
