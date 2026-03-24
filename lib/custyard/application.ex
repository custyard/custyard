defmodule Custyard.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        CustyardWeb.Telemetry,
        Custyard.Repo,
        {DNSCluster, query: Application.get_env(:custyard, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Custyard.PubSub},
        {Finch, name: Custyard.Finch},
        CustyardWeb.Endpoint
      ]
      |> maybe_add_scheduler()

    opts = [strategy: :one_for_one, name: Custyard.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_scheduler(children) do
    if Application.get_env(:custyard, :start_scheduler, true) do
      [Custyard.Scoring.Scheduler | children]
    else
      children
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    CustyardWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
