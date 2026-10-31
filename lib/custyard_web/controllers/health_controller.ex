defmodule CustyardWeb.HealthController do
  @moduledoc """
  Health check endpoint for container orchestrators.

  Returns 200 when all core services are healthy:
  - Database: SELECT 1 succeeds
  - PubSub: Phoenix.PubSub process is alive
  - Scheduler: Scoring.Scheduler process is alive (if started)
  - TaskSupervisor: For async webhook processing

  Returns 503 with details when any check fails.

  ## Security Notes

  This endpoint is intentionally unauthenticated to allow container orchestrators
  (Kubernetes, Fly.io, etc.) to probe service health. The endpoint exposes minimal
  information about service status. For high-security deployments, consider:
  - Restricting access at the load balancer level to internal IPs
  - Using a shared secret query parameter for orchestrator probes
  """
  use CustyardWeb, :controller

  alias Ecto.Adapters.SQL

  require Custyard.Log, as: Log

  def index(conn, _params) do
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
