defmodule Mix.Tasks.Acknowledgments.Bind do
  @shortdoc "Bind a source organization ID to a Custyard organization, idempotently"
  @moduledoc "Usage: `mix acknowledgments.bind SOURCE SOURCE_ORG_ID CUSTYARD_ORG_ID`. See `bin/acknowledgments help`."
  use Mix.Task
  alias Custyard.Release.Acknowledgments, as: Commands

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case Commands.run(["bind" | args], actor: "mix") do
      0 -> :ok
      status -> exit({:shutdown, status})
    end
  end
end
