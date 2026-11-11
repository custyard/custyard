defmodule Custyard.Acknowledgments.Subscription do
  @moduledoc "A tenant-local restart budget; exhausted subscriptions stop without affecting siblings."
  use Supervisor
  alias Custyard.Acknowledgments.Consumer

  def child_spec(opts) do
    %{
      id: {Consumer, Keyword.fetch!(opts, :tenant_id)},
      start: {__MODULE__, :start_link, [opts]},
      type: :supervisor,
      restart: :temporary
    }
  end

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    Supervisor.init([{Consumer, opts}], strategy: :one_for_one, max_restarts: 3, max_seconds: 5)
  end
end
