defmodule Mix.Tasks.Acknowledgments.Status do
  @shortdoc "Show acknowledgment configuration and queue counts"
  @moduledoc "Usage: `mix acknowledgments.status`. See `bin/acknowledgments help`."
  use Mix.Task
  alias Custyard.Release.Acknowledgments, as: Commands

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    case Commands.run(["status" | args], actor: "mix") do
      0 -> :ok
      status -> exit({:shutdown, status})
    end
  end
end
