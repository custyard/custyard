defmodule CustyardWeb.AttachmentDownloadTest do
  @moduledoc """
  How `CustyardWeb.AttachmentDownload` moves stored content to a client. Who
  may download what is covered by the staff and portal controller tests.
  """
  use CustyardWeb.ConnCase, async: true

  import Custyard.Factory
  import Ecto.Query

  alias Custyard.{Attachments, Files, MessageAttachment, Repo}
  alias Custyard.Files.{Chunk, StoredFile}
  alias CustyardWeb.AttachmentDownload
  alias Ecto.Adapters.SQL.Sandbox

  @mib 1_048_576
  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "rest">>

  defmodule Client do
    @moduledoc false
    # Stands in for the web server: a client that takes `left` parts of a
    # chunked response, reporting the size of each, and then hangs up.
    def send_chunked(payload, _status, _headers), do: {:ok, nil, payload}

    def chunk(%{left: 0}, _body), do: {:error, :closed}

    def chunk(%{left: left, test: test} = payload, body) do
      send(test, {:part, IO.iodata_length(body)})
      {:ok, nil, %{payload | left: left - 1}}
    end
  end

  setup do
    thread = insert_thread(organization_id: insert_organization().id)
    %{thread: thread}
  end

  defp fetched(thread, descriptor) do
    {:ok, [row]} =
      Attachments.fetch_for_message(insert_message(thread_id: thread.id), [descriptor])

    row
  end

  defp client_conn(parts), do: %{build_conn() | adapter: {Client, %{test: self(), left: parts}}}

  defp parts_received do
    receive do
      {:part, size} -> [size | parts_received()]
    after
      0 -> []
    end
  end

  # Reports each query this test process makes for file content, which is one
  # per part of the stream, so a test can tell how much of a file was read.
  defp report_content_reads do
    id = {__MODULE__, make_ref()}
    :telemetry.attach(id, [:custyard, :repo, :query], &__MODULE__.handle_query/4, self())
    on_exit(fn -> :telemetry.detach(id) end)
  end

  def handle_query(_event, _measurements, %{source: "stored_file_chunks"}, test) do
    if self() == test, do: send(test, :content_read)
  end

  def handle_query(_event, _measurements, _metadata, _test), do: :ok

  defp content_reads do
    receive do
      :content_read -> 1 + content_reads()
    after
      0 -> 0
    end
  end

  describe "streaming" do
    setup %{thread: thread} do
      bytes = :crypto.strong_rand_bytes(3 * @mib + 4097)
      %{large: fetched(thread, %{filename: "large.bin", content: bytes})}
    end

    test "content goes out in parts of at most a megabyte, read one at a time", %{large: large} do
      report_content_reads()

      conn = AttachmentDownload.send_attachment(client_conn(10), large)

      assert conn.status == 200
      assert conn.state == :chunked
      assert parts_received() == [@mib, @mib, @mib, 4097]
      assert content_reads() == 4
    end

    test "stops reading once the client has gone", %{large: large} do
      report_content_reads()

      conn = AttachmentDownload.send_attachment(client_conn(1), large)

      assert conn.state == :chunked
      assert parts_received() == [@mib]
      # The part the client refused had been read; the two after it were not.
      assert content_reads() == 2
    end

    test "content missing past the first part fails the request", %{large: large} do
      file = Attachments.stored_file(large)
      Repo.delete_all(from c in Chunk, where: c.file_id == ^file.id and c.position == 9)

      # A response that simply ended here would be a short file the client
      # takes for the whole one.
      assert_raise Files.CorruptError, fn ->
        AttachmentDownload.send_attachment(build_conn(), large)
      end

      # The status had gone out by then: it was too late for a 404.
      assert_received {:plug_conn, :sent}
    end

    test "content missing from the start is a 404 with no download headers", %{large: large} do
      file = Attachments.stored_file(large)
      Repo.delete_all(from c in Chunk, where: c.file_id == ^file.id and c.position == 0)

      conn = AttachmentDownload.send_attachment(build_conn(), large)

      assert conn.status == 404
      assert conn.state == :sent
      assert conn.resp_body == "Not found"
      assert get_resp_header(conn, "content-disposition") == []
      assert get_resp_header(conn, "content-security-policy") == []
    end
  end

  # What the web server puts on the wire is not visible on a test conn, so
  # these go through Bandit, the server the endpoint runs on, and read the
  # response off a socket as it arrives.
  describe "over a socket" do
    setup do
      test = self()

      plug = fn conn, _opts ->
        Sandbox.allow(Repo, test, self())

        case conn.path_info do
          ["download", id] ->
            AttachmentDownload.send_attachment(conn, Repo.get!(MessageAttachment, id))

          ["inline", id] ->
            AttachmentDownload.send_inline_image(conn, Repo.get!(MessageAttachment, id))
        end
      end

      server =
        start_supervised!(
          {Bandit, plug: plug, scheme: :http, ip: :loopback, port: 0, startup_log: false}
        )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(server)
      %{port: port}
    end

    # One GET, read until the server closes the connection: the status
    # line, the headers by lowercased name, and the body exactly as sent.
    defp wire_get(port, path, request_headers \\ ["connection: close"]) do
      {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])
      request = ["GET #{path} HTTP/1.1", "host: localhost" | request_headers]
      :ok = :gen_tcp.send(socket, Enum.map(request ++ [""], &[&1, "\r\n"]))

      [head, body] = socket |> receive_all([]) |> :binary.split("\r\n\r\n")
      [status | lines] = String.split(head, "\r\n")

      headers =
        Map.new(lines, fn line ->
          [name, value] = String.split(line, ": ", parts: 2)
          {String.downcase(name), value}
        end)

      {status, headers, body}
    end

    defp receive_all(socket, received) do
      case :gen_tcp.recv(socket, 0, 15_000) do
        {:ok, data} -> receive_all(socket, [received | data])
        {:error, :closed} -> IO.iodata_to_binary(received)
      end
    end

    test "a large attachment arrives byte for byte, with its length and not chunked", %{
      thread: thread,
      port: port
    } do
      bytes = :crypto.strong_rand_bytes(3 * @mib + 4097)
      large = fetched(thread, %{filename: "large.bin", content: bytes})

      {status, headers, body} = wire_get(port, "/download/#{large.id}")

      assert status == "HTTP/1.1 200 OK"
      assert headers["content-length"] == "#{byte_size(bytes)}"
      refute Map.has_key?(headers, "transfer-encoding")
      assert headers["content-disposition"] == ~s(attachment; filename="large.bin")
      assert byte_size(body) == byte_size(bytes)
      assert body == bytes, "the body is not the stored content"
    end

    test "an inline image arrives byte for byte, with its length and not chunked", %{
      thread: thread,
      port: port
    } do
      image = @png <> :crypto.strong_rand_bytes(2 * @mib)
      row = fetched(thread, %{filename: "photo.png", content: image, content_id: "cid-photo"})

      {status, headers, body} = wire_get(port, "/inline/#{row.id}")

      assert status == "HTTP/1.1 200 OK"
      assert headers["content-type"] == "image/png"
      assert headers["content-length"] == "#{byte_size(image)}"
      refute Map.has_key?(headers, "transfer-encoding")
      assert headers["content-disposition"] == ~s(inline; filename="photo.png")
      assert byte_size(body) == byte_size(image)
      assert body == image, "the body is not the stored content"
    end

    test "an empty attachment is a length of zero and no body", %{thread: thread, port: port} do
      empty = fetched(thread, %{filename: "empty.txt", content: ""})

      {status, headers, body} = wire_get(port, "/download/#{empty.id}")

      assert status == "HTTP/1.1 200 OK"
      assert headers["content-length"] == "0"
      refute Map.has_key?(headers, "transfer-encoding")
      assert body == ""
    end

    # The request asks to keep the connection open. The server closes it
    # all the same, short of the length it declared, which is how a client
    # tells a failed download from a finished one.
    @tag capture_log: true
    test "content missing past the first part ends the response short of its length", %{
      thread: thread,
      port: port
    } do
      bytes = :crypto.strong_rand_bytes(3 * @mib + 4097)
      large = fetched(thread, %{filename: "large.bin", content: bytes})
      file = Attachments.stored_file(large)
      Repo.delete_all(from c in Chunk, where: c.file_id == ^file.id and c.position == 9)

      {status, headers, body} = wire_get(port, "/download/#{large.id}", [])

      assert status == "HTTP/1.1 200 OK"
      assert headers["content-length"] == "#{byte_size(bytes)}"
      assert byte_size(body) == 2 * @mib
      assert body == binary_part(bytes, 0, 2 * @mib), "the body is not the stored content"
    end

    # A recorded size that the content does not add up to cannot come from
    # the app; it means the row or the chunks were damaged.
    @tag capture_log: true
    test "content longer or shorter than its recorded size is never sent as a whole body", %{
      thread: thread,
      port: port
    } do
      bytes = :crypto.strong_rand_bytes(2 * @mib)

      for {name, change} <- [{"longer.bin", -100}, {"shorter.bin", 100}] do
        content = bytes <> name
        row = fetched(thread, %{filename: name, content: content})
        file = Attachments.stored_file(row)
        declared = file.size + change
        Repo.update_all(from(f in StoredFile, where: f.id == ^file.id), set: [size: declared])

        {status, headers, body} = wire_get(port, "/download/#{row.id}", [])

        assert status == "HTTP/1.1 200 OK"
        assert headers["content-length"] == "#{declared}"
        assert byte_size(body) < declared, "#{name}: a body of the declared length was sent"
        assert body == binary_part(content, 0, byte_size(body))
      end
    end
  end

  test "an empty attachment is an empty 200", %{thread: thread} do
    empty = fetched(thread, %{filename: "empty.txt", content: ""})
    assert empty.size == 0

    conn = AttachmentDownload.send_attachment(build_conn(), empty)

    assert conn.status == 200
    assert conn.resp_body == ""
    assert get_resp_header(conn, "content-disposition") == [~s(attachment; filename="empty.txt")]
  end

  test "an attachment that is quarantined or not fetched is a 404", %{thread: thread} do
    infected = fetched(thread, %{filename: "x.txt", content: "CUSTYARD_TEST_INFECTED content"})
    assert infected.scan_status == :infected
    assert Attachments.stored_file(infected)

    for attachment <- [infected, %{infected | scan_status: :clean, state: :pending}, nil] do
      assert AttachmentDownload.send_attachment(build_conn(), attachment).status == 404
      assert AttachmentDownload.send_inline_image(build_conn(), attachment).status == 404
    end
  end

  # These responses used to come from Phoenix.Controller.send_download/3. The
  # header a browser names the saved file by must not have changed.
  describe "content-disposition" do
    defp phoenix_disposition(filename, disposition) do
      build_conn()
      |> Phoenix.Controller.send_download({:binary, ""},
        filename: filename,
        disposition: disposition,
        content_type: "application/octet-stream"
      )
      |> get_resp_header("content-disposition")
    end

    test "is what send_download wrote, for names plain and awkward", %{thread: thread} do
      names = [
        "plain.txt",
        "two words.txt",
        "résumé (final).pdf",
        "日本語.txt",
        "100%.txt",
        "a;b=c,d.txt",
        "it's.txt",
        nil
      ]

      for name <- names do
        row = fetched(thread, %{filename: name, content: "named #{name}"})
        conn = AttachmentDownload.send_attachment(build_conn(), row)

        assert conn.status == 200

        assert get_resp_header(conn, "content-disposition") ==
                 phoenix_disposition(row.filename || "attachment", :attachment)
      end
    end

    test "is what send_download wrote for an inline image", %{thread: thread} do
      for name <- ["logo.png", "föto 1.png", nil] do
        row = fetched(thread, %{filename: name, content: @png, content_id: "cid-#{name}"})
        conn = AttachmentDownload.send_inline_image(build_conn(), row)

        assert conn.status == 200
        assert conn.resp_body == @png
        assert get_resp_header(conn, "content-type") == ["image/png"]

        assert get_resp_header(conn, "content-disposition") ==
                 phoenix_disposition(row.filename || "image", :inline)
      end
    end
  end
end
