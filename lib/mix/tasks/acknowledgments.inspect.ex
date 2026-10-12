defmodule Mix.Tasks.Acknowledgments.Inspect do
  @shortdoc "Inspect acknowledgment broker work"
  use Mix.Task
  alias Custyard.Acknowledgments.Operations
  @impl true
  def run([]) do
    Mix.Task.run("app.start")

    case Operations.inspect_failure() do
      {:error, _} -> Mix.raise("Acknowledgment inspect failed; messages remain recoverable")
      result -> Mix.shell().info(inspect(result, limit: :infinity, printable_limit: :infinity))
    end
  end
end
