defmodule Mix.Tasks.Custyard.Lettermint.SyncRoutes do
  @shortdoc "Backfill Lettermint inbound domains on routes that lack one"
  @moduledoc """
  Fetch each Lettermint route whose `lettermint_route_domain` is nil from the
  Lettermint API and store its inbound domain and address.

      mix custyard.lettermint.sync_routes

  Starts only the Repo, not the application, so it works while
  `mix phx.server` is running. Requires the Lettermint client to be
  configured (`LETTERMINT_API_URL`, `LETTERMINT_API_KEY` in production).
  """
  use Mix.Task

  alias Custyard.InboundRoutes

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")

    {:ok, %{synced: synced, failed: failed}, _started} =
      Ecto.Migrator.with_repo(Custyard.Repo, fn _repo ->
        InboundRoutes.sync_remote_routes_missing_domain()
      end)

    Mix.shell().info("Lettermint routes synced: #{synced}, failed: #{failed}")

    if failed > 0, do: exit({:shutdown, 1})
  end
end
