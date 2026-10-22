defmodule Custyard.Email.ImapClient.PloverTest do
  @moduledoc "The Plover wrapper against Plover's mock transport (IMAP4rev1 wire format)."
  use ExUnit.Case, async: true

  alias Custyard.Email.ImapClient.Plover, as: Client
  alias Plover.Transport.Mock

  setup do
    {:ok, socket} = Mock.connect("imap.example.com", 993, [])
    Mock.enqueue_greeting(socket, capabilities: ["IMAP4rev1"])

    {:ok, conn} =
      Client.connect("imap.example.com", 993, plover: [transport: Mock, socket: socket])

    %{socket: socket, conn: conn}
  end

  defp sent(socket), do: socket |> Mock.get_sent() |> IO.iodata_to_binary()

  test "a NO to LOGIN is an authentication failure", %{socket: socket, conn: conn} do
    Mock.enqueue(socket, "A0001 NO [AUTHENTICATIONFAILED] Invalid credentials\r\n")
    assert {:error, :auth_failed} = Client.login(conn, "user", "pass")
  end

  test "EXAMINE opens read-only and reports UIDVALIDITY and UIDNEXT", %{
    socket: socket,
    conn: conn
  } do
    Mock.enqueue(socket, "A0001 OK LOGIN completed\r\n")
    assert :ok = Client.login(conn, "user", "pass")

    Mock.enqueue(
      socket,
      "* 3 EXISTS\r\n* OK [UIDVALIDITY 42] UIDs valid\r\n* OK [UIDNEXT 10] Predicted\r\n" <>
        "A0002 OK [READ-ONLY] EXAMINE completed\r\n"
    )

    assert {:ok, %{uid_validity: 42, uid_next: 10}} = Client.examine(conn, "INBOX")
    assert sent(socket) =~ "EXAMINE INBOX"
    refute sent(socket) =~ "SELECT"
  end

  test "a missing folder is folder_unavailable", %{socket: socket, conn: conn} do
    Mock.enqueue(socket, "A0001 NO Mailbox does not exist\r\n")
    assert {:error, :folder_unavailable} = Client.examine(conn, "Nope")
  end

  test "list_after uses UID FETCH, drops the n:* echo of an older UID and sorts", %{
    socket: socket,
    conn: conn
  } do
    Mock.enqueue(
      socket,
      "* 2 FETCH (UID 12 RFC822.SIZE 300)\r\n* 1 FETCH (UID 11 RFC822.SIZE 200)\r\n" <>
        "A0001 OK FETCH completed\r\n"
    )

    assert {:ok, [%{uid: 11, size: 200}, %{uid: 12, size: 300}]} = Client.list_after(conn, 10)
    assert sent(socket) =~ "UID FETCH 11:* (UID RFC822.SIZE)"

    Mock.enqueue(socket, "* 2 FETCH (UID 12 RFC822.SIZE 300)\r\nA0002 OK FETCH completed\r\n")
    assert {:ok, []} = Client.list_after(conn, 12)
  end

  test "fetch_message peeks so the message stays unread", %{socket: socket, conn: conn} do
    raw = "Subject: Hi\r\n\r\nHello\r\n"

    Mock.enqueue(
      socket,
      "* 1 FETCH (UID 11 BODY[] {#{byte_size(raw)}}\r\n#{raw})\r\nA0001 OK FETCH completed\r\n"
    )

    assert {:ok, ^raw} = Client.fetch_message(conn, 11)
    assert sent(socket) =~ "UID FETCH 11 BODY.PEEK[]"
  end
end
