defmodule Mix.Tasks.Acknowledgments.Provision do
  @shortdoc "Declare the acknowledgment work, retry and failure queues"
  @moduledoc """
  Usage: `mix acknowledgments.provision`. See `bin/acknowledgments help`.

  Runs with the provisioning credential from a trusted workstation, so it never
  starts the application: no consumer can subscribe with that credential.
  """
  use Mix.Task
  alias Custyard.Release.Acknowledgments, as: Commands

  @impl true
  def run(args) do
    Mix.Task.run("app.config")

    case Commands.run(["provision" | args], mode: :release, actor: "mix") do
      0 -> :ok
      status -> exit({:shutdown, status})
    end
  end
end
