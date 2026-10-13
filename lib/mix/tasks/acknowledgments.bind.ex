defmodule Mix.Tasks.Acknowledgments.Bind do
  @shortdoc "Bind a source organization ID to a Custyard organization, idempotently"
  @moduledoc """
  Usage: `mix acknowledgments.bind SOURCE SOURCE_ORG_ID CUSTYARD_ORG_ID`. See
  `bin/acknowledgments help`. Starts only the Repo, never the application.
  """
  use Mix.Task
  alias Custyard.Release.Acknowledgments, as: Commands

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    case Commands.run(["bind" | args], mode: :release, actor: "mix") do
      0 -> :ok
      status -> exit({:shutdown, status})
    end
  end
end
