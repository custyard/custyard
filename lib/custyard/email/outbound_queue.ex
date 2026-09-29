defmodule Custyard.Email.OutboundQueue do
  @moduledoc """
  Drains persisted operator replies awaiting email delivery.

  `Conversations.send_reply/3` commits a pending message before notifying this
  worker. A periodic scan also finds messages left pending by a process crash,
  supervisor saturation, or a lost wake-up. The worker is the sole automatic
  sender in the single-node deployment model.
  """

  use GenServer

  import Ecto.Query

  alias Custyard.{Message, Repo}
  alias Custyard.Email.Outbound

  require Logger

  @scan_interval_ms 30_000
  @batch_size 100

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Wake the worker after a reply commits. The periodic scan is the fallback."
  def wake do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :wake)
    :ok
  end

  @doc "Drain one batch synchronously, used by the worker and focused tests."
  def drain_pending do
    pending =
      from(m in Message,
        where: m.source == :operator and m.delivery_status == :pending,
        order_by: [asc: m.inserted_at, asc: m.id],
        limit: @batch_size
      )
      |> Repo.all()

    Enum.each(pending, fn message ->
      case Outbound.deliver(message) do
        {:ok, _} -> :ok
        {:error, _, _} -> :ok
      end
    end)

    length(pending)
  end

  @impl true
  def init(_opts) do
    # Scan on startup to recover work committed before or during a restart.
    send(self(), :drain)
    {:ok, %{timer_ref: nil}}
  end

  @impl true
  def handle_cast(:wake, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    send(self(), :drain)
    {:noreply, %{state | timer_ref: nil}}
  end

  @impl true
  def handle_info(:drain, state) do
    if state.timer_ref, do: Process.cancel_timer(state.timer_ref)
    count = scan_pending()
    delay = if count == @batch_size, do: 0, else: @scan_interval_ms
    timer_ref = Process.send_after(self(), :drain, delay)
    {:noreply, %{state | timer_ref: timer_ref}}
  end

  defp scan_pending do
    drain_pending()
  rescue
    error ->
      # A fresh installation can start the application before migrations have
      # created messages. Keep the worker alive and retry on the next scan.
      Logger.error("Outbound queue scan failed: #{Exception.message(error)}")
      0
  end
end
