defmodule Custyard.Email.ImapPollers do
  @moduledoc """
  Supervises one `Custyard.Email.ImapChannelPoller` per IMAP channel that
  should be read (spec-inbound-channels, D8). Replaces the single global
  IMAP poller that was configured through `IMAP_*` environment variables.

  A channel is polled while it is `awaiting_first_message` or `active`, has
  a starting position (set when the wizard's connection test succeeds) and
  is not suspended after repeated login failures. The reconciler starts and
  stops pollers on every channel change broadcast on `"inbound_channels"`
  and sweeps all channels every five minutes as a safety net.

  Started by `Custyard.Application` unless
  `config :custyard, start_imap_pollers: false` (tests).
  """
  use Supervisor

  import Ecto.Query

  alias Custyard.{InboundChannel, Repo}

  @registry Custyard.Email.ImapPollerRegistry
  @supervisor Custyard.Email.ImapPollerSupervisor

  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @supervisor, strategy: :one_for_one},
      Custyard.Email.ImapPollers.Reconciler
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc "True when the channel should have a running poller."
  def pollable?(%InboundChannel{} = channel) do
    channel.ingress_kind == :imap and channel.state in [:awaiting_first_message, :active] and
      not is_nil(channel.imap_uid_validity) and is_nil(channel.imap_auth_failed_at)
  end

  def pollable?(nil), do: false

  @doc "IDs of every channel that should have a poller."
  def pollable_channel_ids do
    from(c in InboundChannel,
      where:
        c.ingress_kind == :imap and c.state in [:awaiting_first_message, :active] and
          not is_nil(c.imap_uid_validity) and is_nil(c.imap_auth_failed_at),
      select: c.id
    )
    |> Repo.all()
  end

  @doc "Start or stop the poller for one channel to match its current row."
  def sync(channel_id) when is_integer(channel_id) do
    if pollable?(Repo.get(InboundChannel, channel_id)),
      do: ensure_started(channel_id),
      else: stop(channel_id)
  end

  @doc "Running poller pid for a channel, or nil."
  def whereis(channel_id) do
    case Registry.lookup(@registry, channel_id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc false
  def via(channel_id), do: {:via, Registry, {@registry, channel_id}}

  defp ensure_started(channel_id) do
    case DynamicSupervisor.start_child(
           @supervisor,
           {Custyard.Email.ImapChannelPoller, channel_id}
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp stop(channel_id) do
    case whereis(channel_id) do
      nil -> :ok
      pid -> DynamicSupervisor.terminate_child(@supervisor, pid)
    end

    :ok
  end

  defmodule Reconciler do
    @moduledoc false
    use GenServer

    alias Custyard.Email.ImapPollers

    @sweep_interval_ms 5 * 60_000

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

    @impl true
    def init(_opts) do
      Phoenix.PubSub.subscribe(Custyard.PubSub, "inbound_channels")
      send(self(), :sweep)
      {:ok, %{}}
    end

    @impl true
    def handle_info({:channel_updated, channel_id}, state) do
      ImapPollers.sync(channel_id)
      {:noreply, state}
    end

    def handle_info(:sweep, state) do
      Enum.each(ImapPollers.pollable_channel_ids(), &ImapPollers.sync/1)
      Process.send_after(self(), :sweep, @sweep_interval_ms)
      {:noreply, state}
    end

    def handle_info(_message, state), do: {:noreply, state}
  end
end
