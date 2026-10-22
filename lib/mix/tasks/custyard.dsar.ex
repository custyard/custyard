defmodule Mix.Tasks.Custyard.Dsar do
  @shortdoc "Export or erase a data subject's messages (bin/dsar in a release)"
  @moduledoc """
  Usage: `mix custyard.dsar export|erase|erase-contact EMAIL --org ID [--yes]`.
  Run `mix custyard.dsar help` for the actions; `bin/dsar` runs the same code
  in a release (`Custyard.Release.Dsar`).

  Starts only the Repo, so it works while the server is running. A usage
  error, a refused erasure or a failure exits with status 1.
  """

  use Mix.Task

  alias Custyard.Release.Dsar

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")

    case Dsar.run(args) do
      0 -> :ok
      status -> exit({:shutdown, status})
    end
  end
end
