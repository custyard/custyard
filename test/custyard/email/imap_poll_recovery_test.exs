defmodule Custyard.Email.ImapPollRecoveryTest do
  @moduledoc """
  IMAP sessions that depend on global configuration: attachment storage
  failing and recovering, and credential key rotation
  (spec-inbound-channels D8, D9).
  """
  # async: false - changes :attachment_dir and :credential_keys.
  use Custyard.DataCase, async: false

  import Custyard.Factory

  alias Custyard.{Attachments, Thread, InboundChannel, InboundChannels, Message}
  alias Custyard.{Credentials, MessageAttachment}
  alias Custyard.Email.ImapClient.Stub
  alias Custyard.Email.ImapPoll

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

    insert_inbound_route_webhook(inbound_route_id: route.id, purpose: :sender_matching)
    %{route: route, host: Stub.mailbox()}
  end

  defp create_imap(route, host) do
    InboundChannels.create_channel(route, %{
      public_address: "support@acme.example.com",
      ingress_kind: :imap,
      imap_host: host,
      imap_username: "support@acme.example.com",
      imap_password: "secret"
    })
  end

  defp connected!(route, host) do
    {:ok, channel} = create_imap(route, host)
    {:ok, channel} = InboundChannels.connect_imap(channel)
    channel
  end

  defp reload(channel), do: Repo.get!(InboundChannel, channel.id)

  defp with_attachment(opts \\ []) do
    message_id =
      if Keyword.get(opts, :message_id, true),
        do: "Message-ID: <imap-attach-#{System.unique_integer([:positive])}@example.com>\r\n",
        else: ""

    "From: Customer <c@example.com>\r\n" <>
      "To: support@acme.example.com\r\n" <>
      "Subject: Invoice\r\n" <>
      message_id <>
      "MIME-Version: 1.0\r\n" <>
      "Content-Type: multipart/mixed; boundary=\"b1\"\r\n\r\n" <>
      "--b1\r\nContent-Type: text/plain\r\n\r\nSee attached.\r\n" <>
      "--b1\r\nContent-Type: application/pdf; name=\"invoice.pdf\"\r\n" <>
      "Content-Disposition: attachment; filename=\"invoice.pdf\"\r\n" <>
      "Content-Transfer-Encoding: base64\r\n\r\n" <>
      Base.encode64("%PDF-1.4 #{System.unique_integer([:positive])}") <> "\r\n--b1--\r\n"
  end

  # A regular file where the attachment directory's parent should be, so
  # every write fails until the directory is restored.
  defp block_attachment_storage(tmp_dir) do
    original = Application.fetch_env!(:custyard, :attachment_dir)
    blocker = Path.join(tmp_dir, "blocker")
    File.write!(blocker, "")
    Application.put_env(:custyard, :attachment_dir, Path.join(blocker, "attachments"))
    on_exit(fn -> Application.put_env(:custyard, :attachment_dir, original) end)
    original
  end

  # A write that raised leaves its slot leased for five minutes; the next
  # poll comes later than that.
  defp expire_attachment_leases do
    Repo.update_all(MessageAttachment, set: [processing_expires_at: nil])
  end

  describe "attachments that cannot be stored" do
    @describetag :tmp_dir

    test "stop the session and are stored by a later poll without a second copy",
         %{route: route, host: host, tmp_dir: tmp_dir} do
      channel = connected!(route, host)
      Stub.put_message(host, 1, with_attachment())
      original = block_attachment_storage(tmp_dir)

      assert {:error, "attachments_failed"} = ImapPoll.poll(reload(channel))

      stored = reload(channel)
      assert stored.imap_last_uid == 0
      assert stored.imap_last_error == "attachments_failed"
      assert stored.imap_message_attempts == 1
      assert [message] = Repo.all(Message)
      assert [%{state: state}] = Attachments.list_for_message(message.id)
      assert state in [:pending, :failed]

      Application.put_env(:custyard, :attachment_dir, original)
      expire_attachment_leases()

      assert {:ok, %{imported: 1}} = ImapPoll.poll(stored)

      stored = reload(channel)
      assert stored.imap_last_uid == 1
      assert stored.imap_message_attempts == 0
      assert Repo.aggregate(Thread, :count) == 1
      assert [^message] = Repo.all(Message)
      assert [%{state: :fetched}] = Attachments.list_for_message(message.id)
    end

    test "a retried message without a Message-ID is not stored twice",
         %{route: route, host: host, tmp_dir: tmp_dir} do
      channel = connected!(route, host)
      Stub.put_message(host, 1, with_attachment(message_id: false))
      original = block_attachment_storage(tmp_dir)

      assert {:error, "attachments_failed"} = ImapPoll.poll(reload(channel))

      Application.put_env(:custyard, :attachment_dir, original)
      expire_attachment_leases()

      assert {:ok, %{imported: 1}} = ImapPoll.poll(reload(channel))
      assert [message] = Repo.all(Message)
      assert message.message_id == nil
      assert [%{state: :fetched}] = Attachments.list_for_message(message.id)
    end

    test "are passed over after five sessions so the folder keeps moving",
         %{route: route, host: host, tmp_dir: tmp_dir} do
      channel = connected!(route, host)
      Stub.put_message(host, 1, with_attachment())

      Stub.put_message(
        host,
        2,
        "From: Other <o@example.com>\r\nTo: support@acme.example.com\r\n" <>
          "Subject: Plain\r\nMessage-ID: <imap-plain-#{System.unique_integer([:positive])}@example.com>\r\n" <>
          "\r\nNo attachment.\r\n"
      )

      block_attachment_storage(tmp_dir)

      for attempt <- 1..4 do
        assert {:error, "attachments_failed"} = ImapPoll.poll(reload(channel))
        assert reload(channel).imap_message_attempts == attempt
      end

      assert {:ok, %{failed: 1, imported: 1}} = ImapPoll.poll(reload(channel))

      stored = reload(channel)
      assert stored.imap_last_uid == 2
      assert stored.imap_message_attempts == 0
      assert stored.imap_last_error == nil
      assert Repo.aggregate(Message, :count) == 2
    end
  end

  describe "credential keys" do
    setup do
      original = Application.get_env(:custyard, :credential_keys)
      on_exit(fn -> Application.put_env(:custyard, :credential_keys, original) end)
      %{keys: original}
    end

    test "refuses to store a password without an encryption key", %{route: route, host: host} do
      Application.put_env(:custyard, :credential_keys, current: nil, previous: [])

      assert {:error, changeset} = create_imap(route, host)
      assert {msg, _} = changeset.errors[:imap_password]
      assert msg =~ "CREDENTIAL_ENCRYPTION_KEY"
    end

    test "a poll moves a password sealed with the previous key to the current one",
         %{route: route, host: host, keys: keys} do
      channel = connected!(route, host)
      rotate_key(keys)
      assert Credentials.stale?(reload(channel).imap_password_ciphertext)

      assert {:ok, _counts} = ImapPoll.poll(reload(channel))

      stored = reload(channel)
      refute Credentials.stale?(stored.imap_password_ciphertext)
      assert {:ok, "secret"} = InboundChannel.imap_password(stored)
    end

    test "a password saved while a poll logs in survives the re-encryption",
         %{route: route, host: host, keys: keys} do
      channel = connected!(route, host)
      rotate_key(keys)

      Stub.update(host, fn state ->
        Map.put(state, :on_login, fn ->
          {:ok, _} = InboundChannels.update_channel(reload(channel), %{imap_password: "new-one"})
        end)
      end)

      ImapPoll.poll(reload(channel))

      assert {:ok, "new-one"} = InboundChannel.imap_password(reload(channel))
    end
  end

  defp rotate_key(keys) do
    Application.put_env(:custyard, :credential_keys,
      current: :crypto.strong_rand_bytes(32),
      previous: [Keyword.fetch!(keys, :current)]
    )
  end
end
