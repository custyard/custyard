defmodule Custyard.Acknowledgments.Subscriptions do
  @moduledoc "Supervises each enabled tenant subscription independently."
  use Supervisor
  import Ecto.Query
  alias Custyard.Acknowledgments.{Consumer, Integration, Subscription}

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  def refresh(tenant_id) do
    if Process.whereis(__MODULE__) do
      id = {Consumer, tenant_id}
      Supervisor.terminate_child(__MODULE__, id)
      Supervisor.delete_child(__MODULE__, id)

      case Custyard.Repo.one(
             from i in Integration,
               join: t in assoc(i, :tenant),
               where: i.tenant_id == ^tenant_id and i.enabled and t.status == "active",
               select: i.id
           ) do
        nil ->
          :ok

        _ ->
          Supervisor.start_child(
            __MODULE__,
            {Subscription, [tenant_id: tenant_id]}
          )
      end
    else
      :ok
    end
  end

  @impl true
  def init(_opts) do
    children =
      Custyard.Repo.all(
        from i in Integration,
          join: t in assoc(i, :tenant),
          where: i.enabled and t.status == "active",
          select: i.tenant_id
      )
      |> Enum.map(fn tenant_id ->
        {Subscription, [tenant_id: tenant_id]}
      end)

    Supervisor.init(children, strategy: :one_for_one)
  end
end
