defmodule Custyard.Email.ImapChannelPoller do
  @moduledoc """
  Polls one IMAP channel on an interval (`config :custyard,
  :imap_poll_interval_ms`, default 60 s) through
  `Custyard.Email.ImapPoll.poll/2`. After failures the interval doubles per
  consecutive failure, up to 15 minutes. The process holds no credentials:
  each poll reloads the channel row, and stops itself once the channel is
  no longer pollable (`Custyard.Email.ImapPollers.pollable?/1`).
  """
  use GenServer, restart: :transient

  alias Custyard.{InboundChannel, Repo}
  alias Custyard.Email.{ImapPoll, ImapPollers}

  @max_backoff_ms 15 * 60_000

  def start_link(channel_id),
    do: GenServer.start_link(__MODULE__, channel_id, name: ImapPollers.via(channel_id))

  @doc "Poll now instead of waiting for the next tick."
  def poll_now(channel_id) do
    case ImapPollers.whereis(channel_id) do
      nil ->
        {:error, :not_running}

      pid ->
        send(pid, :poll)
        :ok
    end
  end

  @impl true
  def init(channel_id) do
    # Spread pollers started together (boot) over the first few seconds.
    Process.send_after(self(), :poll, :rand.uniform(5_000))
    {:ok, %{channel_id: channel_id, timer: nil}}
  end

  @impl true
  def handle_info(:poll, state) do
    channel = Repo.get(InboundChannel, state.channel_id)

    if ImapPollers.pollable?(channel) do
      _ = ImapPoll.poll(channel)
      {:noreply, schedule(state)}
    else
      {:stop, :normal, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp schedule(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    failures = failures(state.channel_id)
    interval = Application.get_env(:custyard, :imap_poll_interval_ms, 60_000)
    delay = min(interval * Integer.pow(2, min(failures, 10)), @max_backoff_ms)
    %{state | timer: Process.send_after(self(), :poll, delay)}
  end

  defp failures(channel_id) do
    case Repo.get(InboundChannel, channel_id) do
      %InboundChannel{imap_consecutive_failures: n} when is_integer(n) -> n
      _ -> 0
    end
  end
end
