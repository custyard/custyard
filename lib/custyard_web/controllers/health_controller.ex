defmodule CustyardWeb.HealthController do
  @moduledoc """
  Health check endpoint for container orchestrators.

  Returns 200 when the application is running and the database is accessible.
  Returns 503 when the database is unreachable.
  """
  use CustyardWeb, :controller

  alias Ecto.Adapters.SQL

  require Logger

  def index(conn, _params) do
    case SQL.query(Custyard.Repo, "SELECT 1") do
      {:ok, _} ->
        conn
        |> put_status(200)
        |> json(%{status: "ok"})

      {:error, reason} ->
        Logger.error("Health check failed: #{inspect(reason)}")

        conn
        |> put_status(503)
        |> json(%{status: "error"})
    end
  end
end
