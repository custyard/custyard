defmodule Mix.Tasks.Acknowledgments.Inspect do
  @shortdoc "Summarize the oldest failed acknowledgment (--evidence prints it whole)"
  @moduledoc "Usage: `mix acknowledgments.inspect [--evidence]`. See `bin/acknowledgments help`."
  use Mix.Task
  alias Custyard.Release.Acknowledgments, as: Commands

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case Commands.run(["inspect" | args], actor: "mix") do
      0 -> :ok
      status -> exit({:shutdown, status})
    end
  end
end
