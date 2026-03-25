defmodule CustyardWeb.HealthController do
  @moduledoc """
  Health check endpoint for container orchestrators.

  Returns 200 when the application is running and the database is accessible.
  Returns 503 when the database is unreachable.
  """
  use CustyardWeb, :controller

  def index(conn, _params) do
    case Ecto.Adapters.SQL.query(Custyard.Repo, "SELECT 1") do
      {:ok, _} ->
        conn
        |> put_status(200)
        |> json(%{status: "ok"})

      {:error, reason} ->
        conn
        |> put_status(503)
        |> json(%{status: "error", reason: inspect(reason)})
    end
  end
end
