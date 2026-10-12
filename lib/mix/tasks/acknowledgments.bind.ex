defmodule Mix.Tasks.Acknowledgments.Bind do
  @shortdoc "Bind a source organization ID to a Custyard organization, idempotently"
  use Mix.Task

  @impl true
  def run([source, external_id, organization_id]) do
    Mix.Task.run("app.start")

    case Integer.parse(organization_id) do
      {id, ""} when id > 0 ->
        case Custyard.Acknowledgments.bind(source, external_id, id) do
          {:ok, _} ->
            Mix.shell().info("Acknowledgment organization mapping is ready")

          {:error, :conflicting_binding} ->
            Mix.raise("Source organization is already bound elsewhere")

          {:error, _} ->
            Mix.raise("Invalid mapping; verify identities and the Custyard organization")
        end

      _ ->
        Mix.raise("Custyard organization ID must be a positive integer")
    end
  end

  def run(_), do: Mix.raise("Usage: mix acknowledgments.bind SOURCE OTS_ORG_ID CUSTYARD_ORG_ID")
end
