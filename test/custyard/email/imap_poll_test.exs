defmodule Custyard.Email.ImapPollTest do
  @moduledoc "IMAP channels (spec-inbound-channels D8): connection, position, import."
  use Custyard.DataCase, async: true

  import Custyard.Factory

  alias Custyard.{Conversation, InboundChannel, InboundChannelRejection, InboundChannels, Message}
  alias Custyard.Email.{ImapPoll, ImapPollers, Parser}
  alias Custyard.Email.ImapClient.Stub
  alias Custyard.Webhooks.Adapters.Email, as: EmailAdapter
  alias Custyard.Webhooks.Dispatcher

  setup do
    org = insert_organization(name: "Acme")

    route =
      insert_inbound_route(
        organization_id: org.id,
        route_type: :general,
        source: :lettermint,
        lettermint_route_id: "lm_#{System.unique_integer([:positive])}",
        lettermint_route_domain: "r#{System.unique_integer([:positive])}.lettermint.app"
      )

    for purpose <- [:sender_matching, :audit] do
      insert_inbound_route_webhook(inbound_route_id: route.id, purpose: purpose, enabled: true)
    end

    host = Stub.mailbox()
    %{org: org, route: route, host: host}
  end

  defp create_imap(route, host, extra \\ %{}) do
    InboundChannels.create_channel(
      route,
      Map.merge(
        %{
          public_address: "support@acme.example.com",
          ingress_kind: :imap,
          imap_host: host,
          imap_username: "support@acme.example.com",
          imap_password: "secret"
        },
        extra
      )
    )
  end

  defp connected!(route, host) do
    {:ok, channel} = create_imap(route, host)
    {:ok, channel} = InboundChannels.connect_imap(channel)
    channel
  end

  defp email(n, opts \\ []) do
    from = Keyword.get(opts, :from, "Customer #{n} <customer#{n}@example.com>")

    "From: #{from}\r\n" <>
      "To: support@acme.example.com\r\n" <>
      "Subject: Question #{n}\r\n" <>
      "Message-ID: <imap-#{n}-#{System.unique_integer([:positive])}@example.com>\r\n" <>
      "MIME-Version: 1.0\r\n" <>
      "Content-Type: text/plain; charset=utf-8\r\n" <>
      "\r\n" <>
      "Body of question #{n}.\r\n"
  end

  defp reload(channel), do: Repo.get!(InboundChannel, channel.id)

  describe "creating an IMAP channel" do
    test "stores the password only as ciphertext", %{route: route, host: host} do
      assert {:ok, channel} = create_imap(route, host)

      assert channel.state == :pending_verification
      assert channel.imap_port == 993
      assert channel.imap_folder == "INBOX"
      assert channel.provider == nil
      assert channel.imap_password == nil
      refute channel.imap_password_ciphertext =~ "secret"
      assert {:ok, "secret"} = InboundChannel.imap_password(reload(channel))
      assert InboundChannels.ingress_address(channel) == nil
    end

    test "requires host, username and password", %{route: route} do
      assert {:error, changeset} =
               InboundChannels.create_channel(route, %{
                 public_address: "support@acme.example.com",
                 ingress_kind: :imap
               })

      assert changeset.errors[:imap_host]
      assert changeset.errors[:imap_username]
      assert changeset.errors[:imap_password]
    end

    test "forwarding channels ignore IMAP attributes", %{route: route} do
      {:ok, channel} =
        InboundChannels.create_channel(route, %{
          public_address: "help@acme.example.com",
          imap_host: "imap.example.com",
          imap_password: "secret"
        })

      assert channel.imap_host == nil
      assert channel.imap_password_ciphertext == nil
      assert channel.imap_port == nil
    end
  end

  describe "connect_imap/2" do
    test "records the current highest UID so existing mail is not imported",
         %{route: route, host: host} do
      Stub.put_message(host, 7, email(7))
      Stub.put_message(host, 9, email(9))

      {:ok, channel} = create_imap(route, host)
      assert {:ok, channel} = InboundChannels.connect_imap(channel)

      assert channel.state == :awaiting_first_message
      assert channel.imap_uid_validity == 1
      assert channel.imap_last_uid == 9
      assert channel.imap_last_error == nil
      assert ImapPollers.pollable?(reload(channel))
      assert Repo.aggregate(Conversation, :count) == 0
    end

    test "a rejected login is recorded and leaves the channel pending",
         %{route: route, host: host} do
      {:ok, channel} = create_imap(route, host, %{imap_password: "wrong"})

      assert {:error, "auth_failed"} = InboundChannels.connect_imap(channel)

      channel = reload(channel)
      assert channel.state == :pending_verification
      assert channel.imap_last_error == "auth_failed"
      assert channel.imap_consecutive_failures == 1
      refute ImapPollers.pollable?(channel)
    end

    test "a missing folder is reported", %{route: route, host: host} do
      {:ok, channel} = create_imap(route, host, %{imap_folder: "Support"})
      assert {:error, "folder_unavailable"} = InboundChannels.connect_imap(channel)
    end

    test "an unreachable server is reported", %{route: route} do
      host = Stub.mailbox(connect_error: :econnrefused)
      {:ok, channel} = create_imap(route, host)
      assert {:error, "connect_failed"} = InboundChannels.connect_imap(channel)
    end
  end

  describe "poll/2" do
    test "imports new mail in UID order onto the channel without touching the mailbox",
         %{route: route, host: host} do
      Stub.put_message(host, 3, email(3))
      channel = connected!(route, host)

      Stub.put_message(host, 5, email(5))
      Stub.put_message(host, 4, email(4))

      assert {:ok, %{imported: 2, skipped: 0, failed: 0}} = ImapPoll.poll(reload(channel))

      channel = reload(channel)
      assert channel.imap_last_uid == 5
      assert channel.state == :active
      assert channel.imap_last_polled_at

      subjects =
        from(c in Conversation, where: c.inbound_channel_id == ^channel.id, order_by: c.id)
        |> Repo.all()
        |> Enum.map(& &1.subject)

      assert subjects == ["Question 4", "Question 5"]

      allowed = fn
        call when call in [:connect, :login, :logout] -> true
        {op, _} when op in [:examine, :list_after, :fetch] -> true
        _ -> false
      end

      assert Enum.all?(Stub.calls(host), allowed)

      # Nothing new: the next poll imports nothing.
      assert {:ok, %{imported: 0}} = ImapPoll.poll(reload(channel))
    end

    test "imports at most one batch per session", %{route: route, host: host} do
      channel = connected!(route, host)
      count = ImapPoll.max_messages_per_poll() + 2
      for uid <- 1..count, do: Stub.put_message(host, uid, email(uid))

      assert {:ok, %{imported: imported}} = ImapPoll.poll(reload(channel))
      assert imported == ImapPoll.max_messages_per_poll()
      assert reload(channel).imap_last_uid == ImapPoll.max_messages_per_poll()

      assert {:ok, %{imported: 2}} = ImapPoll.poll(reload(channel))
    end

    test "logs oversized and unreadable messages and moves past them",
         %{route: route, host: host} do
      channel = connected!(route, host)
      Stub.put_message(host, 1, email(1))
      Stub.put_message(host, 2, "")
      Stub.put_message(host, 3, email(3))
      Stub.update(host, &put_in(&1, [:sizes, 1], ImapPoll.max_message_bytes() + 1))

      assert {:ok, %{imported: 1, skipped: 2}} = ImapPoll.poll(reload(channel))
      assert reload(channel).imap_last_uid == 3
      refute {:fetch, 1} in Stub.calls(host)

      classes =
        from(r in InboundChannelRejection, where: r.inbound_channel_id == ^channel.id)
        |> Repo.all()
        |> Enum.map(& &1.classification)
        |> Enum.sort()

      assert classes == [:too_large, :unreadable]
    end

    test "a fetch failure stops the session before the failing UID",
         %{route: route, host: host} do
      channel = connected!(route, host)
      Stub.put_message(host, 1, email(1))
      Stub.put_message(host, 2, email(2))
      Stub.put_message(host, 3, email(3))
      Stub.update(host, &put_in(&1, [:fetch_error, 2], :closed))

      assert {:error, "fetch_failed"} = ImapPoll.poll(reload(channel))

      channel = reload(channel)
      assert channel.imap_last_uid == 1
      assert channel.imap_last_error == "fetch_failed"
      assert channel.imap_consecutive_failures == 1

      Stub.update(host, &Map.put(&1, :fetch_error, %{}))
      assert {:ok, %{imported: 2}} = ImapPoll.poll(channel)
      assert reload(channel).imap_consecutive_failures == 0
    end

    test "a changed UIDVALIDITY resets the position without importing",
         %{route: route, host: host} do
      channel = connected!(route, host)
      Stub.put_message(host, 1, email(1))
      Stub.update(host, &Map.put(&1, :uid_validity, 2))

      assert {:ok, %{rebased: true, imported: 0}} = ImapPoll.poll(reload(channel))

      channel = reload(channel)
      assert channel.imap_uid_validity == 2
      assert channel.imap_last_uid == 1
      assert Repo.aggregate(Message, :count) == 0
    end

    test "three rejected logins stop polling until the password changes",
         %{route: route, host: host} do
      channel = connected!(route, host)
      Stub.update(host, &Map.put(&1, :password, "rotated"))

      for _ <- 1..3, do: assert({:error, "auth_failed"} = ImapPoll.poll(reload(channel)))

      channel = reload(channel)
      assert channel.imap_auth_failed_at
      assert channel.imap_auth_failures == 3
      refute ImapPollers.pollable?(channel)

      {:ok, channel} = InboundChannels.update_channel(channel, %{imap_password: "rotated"})
      assert channel.imap_auth_failed_at == nil
      assert channel.imap_auth_failures == 0
      assert channel.imap_consecutive_failures == 0
      assert {:ok, %{}} = ImapPoll.poll(channel)
    end

    test "other failures neither count as rejected logins nor reset them",
         %{route: route, host: host} do
      channel = connected!(route, host)

      Stub.update(host, &Map.put(&1, :connect_error, :timeout))
      assert {:error, "timeout"} = ImapPoll.poll(reload(channel))

      Stub.update(host, &%{&1 | connect_error: nil, password: "rotated"})
      for _ <- 1..2, do: assert({:error, "auth_failed"} = ImapPoll.poll(reload(channel)))

      channel = reload(channel)
      assert channel.imap_consecutive_failures == 3
      assert channel.imap_auth_failures == 2
      assert channel.imap_auth_failed_at == nil
      assert ImapPollers.pollable?(channel)

      Stub.update(host, &Map.put(&1, :connect_error, :timeout))
      assert {:error, "timeout"} = ImapPoll.poll(channel)
      Stub.update(host, &Map.put(&1, :connect_error, nil))
      assert {:error, "auth_failed"} = ImapPoll.poll(reload(channel))
      assert reload(channel).imap_auth_failed_at
    end

    test "a successful poll clears rejected logins", %{route: route, host: host} do
      channel = connected!(route, host)
      Stub.update(host, &Map.put(&1, :password, "rotated"))
      for _ <- 1..2, do: ImapPoll.poll(reload(channel))

      Stub.update(host, &Map.put(&1, :password, "secret"))
      assert {:ok, _counts} = ImapPoll.poll(reload(channel))
      assert reload(channel).imap_auth_failures == 0

      Stub.update(host, &Map.put(&1, :password, "rotated"))
      for _ <- 1..2, do: ImapPoll.poll(reload(channel))
      assert reload(channel).imap_auth_failed_at == nil
    end

    test "reconnecting after a lockout imports what arrived during it",
         %{route: route, host: host} do
      channel = connected!(route, host)
      Stub.update(host, &Map.put(&1, :password, "rotated"))
      for _ <- 1..3, do: ImapPoll.poll(reload(channel))
      assert reload(channel).imap_auth_failed_at

      Stub.put_message(host, 1, email(1))

      {:ok, channel} =
        InboundChannels.update_channel(reload(channel), %{imap_password: "rotated"})

      assert {:ok, channel} = InboundChannels.connect_imap(channel)
      assert channel.imap_last_uid == 0
      assert ImapPollers.pollable?(channel)

      assert {:ok, %{imported: 1}} = ImapPoll.poll(channel)
    end

    test "a connection test on an active channel keeps its position",
         %{route: route, host: host} do
      channel = connected!(route, host)
      Stub.put_message(host, 1, email(1))

      assert {:ok, channel} = InboundChannels.connect_imap(reload(channel))
      assert channel.imap_last_uid == 0
      assert {:ok, %{imported: 1}} = ImapPoll.poll(channel)
    end

    test "changing the mailbox resets the position", %{route: route, host: host} do
      channel = connected!(route, host)
      other = Stub.mailbox()

      {:ok, channel} = InboundChannels.update_channel(channel, %{imap_host: other})
      assert channel.imap_uid_validity == nil
      assert channel.imap_last_uid == nil
      refute ImapPollers.pollable?(channel)
    end

    test "mail fetched while the channel is paused goes to the rejection log",
         %{route: route, host: host} do
      channel = connected!(route, host)
      Stub.put_message(host, 1, email(1))
      {:ok, channel} = InboundChannels.pause(channel)

      assert {:ok, %{ignored: 1}} = ImapPoll.poll(channel)
      assert reload(channel).imap_last_uid == 1

      assert [%{classification: :channel_paused}] =
               InboundChannels.list_rejections_for_route(route.id)

      assert Repo.aggregate(Conversation, :count) == 0
    end
  end

  describe "attachments" do
    test "attachments in the message are stored under the channel cap",
         %{route: route, host: host} do
      channel = connected!(route, host)

      raw =
        "From: Customer <c@example.com>\r\n" <>
          "To: support@acme.example.com\r\n" <>
          "Subject: Invoice\r\n" <>
          "Message-ID: <imap-attach-#{System.unique_integer([:positive])}@example.com>\r\n" <>
          "MIME-Version: 1.0\r\n" <>
          "Content-Type: multipart/mixed; boundary=\"b1\"\r\n\r\n" <>
          "--b1\r\nContent-Type: text/plain\r\n\r\nSee attached.\r\n" <>
          "--b1\r\nContent-Type: application/pdf; name=\"invoice.pdf\"\r\n" <>
          "Content-Disposition: attachment; filename=\"invoice.pdf\"\r\n" <>
          "Content-Transfer-Encoding: base64\r\n\r\n" <>
          Base.encode64("%PDF-1.4 test") <> "\r\n--b1--\r\n"

      Stub.put_message(host, 1, raw)
      assert {:ok, %{imported: 1}} = ImapPoll.poll(reload(channel))

      [message] = Repo.all(from m in Message, where: m.inbound_channel_id == ^channel.id)

      assert [%{state: :fetched, filename: "invoice.pdf", sniffed_type: "application/pdf"}] =
               Custyard.Attachments.list_for_message(message.id)
    end
  end

  describe "dispatch with a known channel" do
    test "refuses a channel from another route", %{route: route, host: host, org: org} do
      channel = connected!(route, host)

      other_route =
        insert_inbound_route(
          organization_id: org.id,
          route_type: :general,
          source: :email
        )

      {:ok, parsed} = Parser.parse(email(1))
      {:ok, normalized} = EmailAdapter.normalize(parsed)

      assert {:error, :channel_route_mismatch} =
               Dispatcher.dispatch(other_route, normalized, channel: channel)
    end
  end
end
