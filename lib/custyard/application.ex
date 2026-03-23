defmodule Custyard.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      CustyardWeb.Telemetry,
      Custyard.Repo,
      {DNSCluster, query: Application.get_env(:custyard, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Custyard.PubSub},
      {Finch, name: Custyard.Finch},
      CustyardWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Custyard.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    CustyardWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
