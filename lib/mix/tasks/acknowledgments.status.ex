defmodule Mix.Tasks.Acknowledgments.Status do
  @shortdoc "Status acknowledgment broker work"
  use Mix.Task
  alias Custyard.Acknowledgments.Operations
  @impl true
  def run([]) do
    Mix.Task.run("app.start")

    case Operations.status() do
      {:error, _} -> Mix.raise("Acknowledgment status failed; messages remain recoverable")
      result -> Mix.shell().info(inspect(result, limit: :infinity, printable_limit: :infinity))
    end
  end
end
