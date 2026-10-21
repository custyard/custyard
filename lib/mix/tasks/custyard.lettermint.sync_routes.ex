defmodule Mix.Tasks.Custyard.Lettermint.SyncRoutes do
  @shortdoc "Backfill Lettermint inbound domains on routes that lack one"
  @moduledoc """
  Fetch each Lettermint route whose `lettermint_route_domain` is nil from the
  Lettermint API and store its inbound domain and address.

      mix custyard.lettermint.sync_routes

  Starts only the Repo and the HTTP client pool (`Custyard.Finch`), not the
  application, so it works while `mix phx.server` is running. Requires the
  Lettermint client to be configured (`LETTERMINT_API_URL`,
  `LETTERMINT_API_KEY` in production).
  """
  use Mix.Task

  alias Custyard.InboundRoutes

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")
    start_http_client()

    {:ok, %{synced: synced, failed: failed}, _started} =
      Ecto.Migrator.with_repo(Custyard.Repo, fn _repo ->
        InboundRoutes.sync_remote_routes_missing_domain()
      end)

    Mix.shell().info("Lettermint routes synced: #{synced}, failed: #{failed}")

    if failed > 0, do: exit({:shutdown, 1})
  end

  # `app.config` does not start the supervision tree, and
  # `Custyard.Lettermint.HttpClient` sends through the `Custyard.Finch` pool
  # that `Custyard.Application` normally owns. Start that pool here (linked
  # to the task) with the same name so the production client works.
  defp start_http_client do
    {:ok, _apps} = Application.ensure_all_started(:ssl)
    {:ok, _apps} = Application.ensure_all_started(:finch)

    case Finch.start_link(name: Custyard.Finch) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end
end
