defmodule CustyardWeb.AttachmentDownloadTest do
  @moduledoc """
  How `CustyardWeb.AttachmentDownload` moves stored content to a client. Who
  may download what is covered by the staff and portal controller tests.
  """
  use CustyardWeb.ConnCase, async: true

  import Custyard.Factory
  import Ecto.Query

  alias Custyard.{Attachments, Files, Repo}
  alias Custyard.Files.Chunk
  alias CustyardWeb.AttachmentDownload

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
