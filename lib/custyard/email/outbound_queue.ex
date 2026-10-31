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

  require Custyard.Log, as: Log

  @scan_interval_ms 30_000
  @batch_size 100
  # A delivery attempt that has not reported back after this long died
  # mid-send (the mailer times out well before). Such rows are failed, not
  # re-sent: the provider may already have accepted the email.
  @stale_sending_seconds 600

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
    fail_stale_sending()

    pending =
      from(m in Message,
        where: m.source == :operator and m.delivery_status == :pending,
        order_by: [asc: m.inserted_at, asc: m.id],
        limit: @batch_size
      )
      |> Repo.all()

    Enum.each(pending, fn message ->
      case Log.operation([message_id: message.id, conversation_id: message.conversation_id], fn ->
             Outbound.deliver(message)
           end) do
        {:ok, _} -> :ok
        {:error, _, _} -> :ok
      end
    end)

    length(pending)
  end

  @doc """
  Mark messages stuck in `:sending` past the grace period as `:failed`.

  A row is `:sending` only between `Outbound.deliver/1` claiming it and the
  mailer reporting back; one left there was interrupted by a crash. Whether
  the provider accepted the email is unknown, so the operator decides on a
  resend rather than the queue delivering it again automatically.
  """
  def fail_stale_sending(grace_seconds \\ @stale_sending_seconds) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    cutoff = DateTime.add(now, -grace_seconds, :second)

    stale =
      from(m in Message,
        where: m.source == :operator and m.delivery_status == :sending,
        where: m.updated_at < ^cutoff
      )
      |> Repo.all()

    Enum.each(stale, fn message ->
      from(m in Message, where: m.id == ^message.id and m.delivery_status == :sending)
      |> Repo.update_all(
        set: [
          delivery_status: :failed,
          delivery_failure_kind: :unknown,
          delivery_error_code: "interrupted",
          updated_at: now
        ]
      )

      Log.warning(:outbound_delivery_interrupted,
        message_id: message.id,
        reason: :acceptance_unknown
      )

      Outbound.broadcast_delivery_update(message)
    end)

    length(stale)
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

  # Mailer adapters may report to the delivering process, which is this one
  # (Swoosh's test adapter sends it every email). A stray message must not
  # take the delivery worker down.
  def handle_info(_message, state), do: {:noreply, state}

  defp scan_pending do
    drain_pending()
  rescue
    error ->
      # A fresh installation can start the application before migrations have
      # created messages. Keep the worker alive and retry on the next scan.
      Log.error(:outbound_queue_scan_failed, Log.failure(error))
      0
  end
end
