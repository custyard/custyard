defmodule Custyard.Email.ImapPollersTest do
  @moduledoc "Poller supervision for IMAP channels (spec-inbound-channels D8)."
  # async: false - pollers run in their own processes on the shared sandbox.
  use Custyard.DataCase, async: false

  import Custyard.Factory

  alias Custyard.{Conversation, InboundChannels}
  alias Custyard.Email.{ImapChannelPoller, ImapPollers}
  alias Custyard.Email.ImapClient.Stub

  setup do
    route =
      insert_inbound_route(
        route_type: :general,
        source: :lettermint,
        lettermint_route_id: "lm_#{System.unique_integer([:positive])}",
        lettermint_route_domain: "r#{System.unique_integer([:positive])}.lettermint.app"
      )

    insert_inbound_route_webhook(
      inbound_route_id: route.id,
      purpose: :sender_matching,
      enabled: true
    )

    start_supervised!(ImapPollers)
    %{route: route, host: Stub.mailbox()}
  end

  defp eventually(fun, attempts \\ 100) do
    cond do
      fun.() -> true
      attempts == 0 -> flunk("condition not met")
      true -> Process.sleep(20) && eventually(fun, attempts - 1)
    end
  end

  test "a connected channel gets a poller that imports on demand and stops when paused",
       %{route: route, host: host} do
    {:ok, channel} =
      InboundChannels.create_channel(route, %{
        public_address: "support@acme.example.com",
        ingress_kind: :imap,
        imap_host: host,
        imap_username: "support@acme.example.com",
        imap_password: "secret"
      })

    assert ImapPollers.whereis(channel.id) == nil

    {:ok, channel} = InboundChannels.connect_imap(channel)
    eventually(fn -> ImapPollers.whereis(channel.id) end)

    Stub.put_message(
      host,
      1,
      "From: c@example.com\r\nTo: support@acme.example.com\r\nSubject: Hi\r\n" <>
        "Message-ID: <poller-1@example.com>\r\n\r\nHello\r\n"
    )

    assert :ok = ImapChannelPoller.poll_now(channel.id)
    eventually(fn -> Repo.aggregate(Conversation, :count) == 1 end)
    eventually(fn -> InboundChannels.get_channel!(channel.id).state == :active end)

    {:ok, _paused} = InboundChannels.pause(InboundChannels.get_channel!(channel.id))
    eventually(fn -> ImapPollers.whereis(channel.id) == nil end)
  end

  test "forwarding channels never get a poller", %{route: route} do
    {:ok, channel} =
      InboundChannels.create_channel(route, %{public_address: "a@acme.example.com"})

    ImapPollers.sync(channel.id)
    assert ImapPollers.whereis(channel.id) == nil
  end
end
