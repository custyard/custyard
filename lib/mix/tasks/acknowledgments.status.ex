defmodule Mix.Tasks.Acknowledgments.Status do
  @shortdoc "Show acknowledgment configuration and queue counts"
  @moduledoc """
  Usage: `mix acknowledgments.status`. See `bin/acknowledgments help`.

  Like every acknowledgments task, this loads configuration without starting
  the application (no consumer, endpoint or background workers) and starts
  only `:amqp` and, where needed, the Repo, exactly as the release command
  does.
  """
  use Mix.Task
  alias Custyard.Release.Acknowledgments, as: Commands

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    case Commands.run(["status" | args], mode: :release, actor: "mix") do
      0 -> :ok
      status -> exit({:shutdown, status})
    end
  end
end
