defmodule CustyardWeb.HealthController do
  @moduledoc """
  Health check endpoint for container orchestrators.

  Returns 200 when all core services are healthy:
  - Database: SELECT 1 succeeds
  - PubSub: Phoenix.PubSub process is alive
  - Scheduler: Scoring.Scheduler process is alive (if started)
  - TaskSupervisor: For async webhook processing

  Returns 503 with details when any check fails.

  `GET /api/health/live` is liveness only: 200 whenever the HTTP process
  answers. Platform checks (Containerfile `HEALTHCHECK`, `fly.toml`, Bunny)
  use it so a container in doctor mode stays up and keeps serving the card
  instead of being restarted (docs/backlog/1103-first-run-experience.md).

  ## Security Notes

  This endpoint is intentionally unauthenticated to allow container orchestrators
  (Kubernetes, Fly.io, etc.) to probe service health. The endpoint exposes minimal
  information about service status. For high-security deployments, consider:
  - Restricting access at the load balancer level to internal IPs
  - Using a shared secret query parameter for orchestrator probes
  """
  use CustyardWeb, :controller

  alias Custyard.Boot.State
  alias Ecto.Adapters.SQL

  require Custyard.Log, as: Log

  # Readiness. In a doctor mode the Repo is not running, so the verdict is
  # the answer; the BootGate lets this path through for exactly this reason.
  def index(conn, _params) do
    case State.mode() do
      :unconfigured -> not_ready(conn, "setup_required", :unconfigured)
      :database_unavailable -> not_ready(conn, "database_unavailable", :database_unavailable)
      _ -> ready_checks(conn)
    end
  end

  defp not_ready(conn, status, mode) do
    conn
    |> put_status(503)
    |> json(%{status: status, mode: mode})
  end

  defp ready_checks(conn) do
    checks = %{
      database: check_database(),
      pubsub: check_pubsub(),
      scheduler: check_scheduler(),
      task_supervisor: check_task_supervisor()
    }

    failed = Enum.filter(checks, fn {_k, v} -> v != :ok end)

    if Enum.empty?(failed) do
      json(conn, %{status: "ok", checks: format_checks(checks)})
    else
      Log.error(:health_check_failed, count: length(failed))

      conn
      |> put_status(503)
      |> json(%{status: "error", checks: format_checks(checks)})
    end
  end

  # Touches no Repo and no named process on purpose.
  def live(conn, _params) do
    json(conn, %{status: "live"})
  end

  defp check_database do
    case SQL.query(Custyard.Repo, "SELECT 1") do
      {:ok, _} -> :ok
      {:error, _reason} -> {:error, "database_unavailable"}
    end
  rescue
    _ -> {:error, "database_unavailable"}
  catch
    :exit, _ -> {:error, "database_unavailable"}
  end

  defp check_pubsub do
    case Process.whereis(Custyard.PubSub) do
      nil -> {:error, "not running"}
      pid when is_pid(pid) -> if Process.alive?(pid), do: :ok, else: {:error, "dead"}
    end
  end

  defp check_scheduler do
    case Process.whereis(Custyard.Scoring.Scheduler) do
      nil ->
        # Scheduler might not be started in test env - that's ok
        if Application.get_env(:custyard, :env, :prod) == :test do
          :ok
        else
          {:error, "not running"}
        end

      pid when is_pid(pid) ->
        if Process.alive?(pid), do: :ok, else: {:error, "dead"}
    end
  end

  defp check_task_supervisor do
    case Process.whereis(Custyard.TaskSupervisor) do
      nil -> {:error, "not running"}
      pid when is_pid(pid) -> if Process.alive?(pid), do: :ok, else: {:error, "dead"}
    end
  end

  defp format_checks(checks) do
    Enum.map(checks, fn
      {k, :ok} -> {k, "ok"}
      {k, {:error, reason}} -> {k, reason}
    end)
    |> Map.new()
  end
end
