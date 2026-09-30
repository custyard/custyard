defmodule Mix.Tasks.Acknowledgments.Provision do
  @shortdoc "Provision acknowledgment broker work"
  use Mix.Task
  alias Custyard.Acknowledgments.Operations
  @impl true
  def run([]) do
    Mix.Task.run("app.start")

    case Operations.provision() do
      {:error, _} -> Mix.raise("Acknowledgment provision failed; messages remain recoverable")
      result -> Mix.shell().info(inspect(result, limit: :infinity, printable_limit: :infinity))
    end
  end
end
