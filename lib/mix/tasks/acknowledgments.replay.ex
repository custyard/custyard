defmodule Mix.Tasks.Acknowledgments.Replay do
  @shortdoc "Replay acknowledgment broker work"
  use Mix.Task
  alias Custyard.Acknowledgments.Operations
  @impl true
  def run([]) do
    Mix.Task.run("app.start")

    case Operations.replay() do
      {:error, _} -> Mix.raise("Acknowledgment replay failed; messages remain recoverable")
      result -> Mix.shell().info(inspect(result, limit: :infinity, printable_limit: :infinity))
    end
  end
end
