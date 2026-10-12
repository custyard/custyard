defmodule Mix.Tasks.Acknowledgments.Provision do
  @shortdoc "Declare the acknowledgment work, retry and failure queues"
  @moduledoc "Usage: `mix acknowledgments.provision`. See `bin/acknowledgments help`."
  use Mix.Task
  alias Custyard.Release.Acknowledgments, as: Commands

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case Commands.run(["provision" | args], actor: "mix") do
      0 -> :ok
      status -> exit({:shutdown, status})
    end
  end
end
