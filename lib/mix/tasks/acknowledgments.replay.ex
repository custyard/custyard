defmodule Mix.Tasks.Acknowledgments.Replay do
  @shortdoc "Replay the oldest failed acknowledgment to the work queue"
  @moduledoc "Usage: `mix acknowledgments.replay [SUBMISSION_ID]`. See `bin/acknowledgments help`."
  use Mix.Task
  alias Custyard.Release.Acknowledgments, as: Commands

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case Commands.run(["replay" | args], actor: "mix") do
      0 -> :ok
      status -> exit({:shutdown, status})
    end
  end
end
