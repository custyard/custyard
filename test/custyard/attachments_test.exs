defmodule Custyard.AttachmentsTest do
  @moduledoc "Attachment fetching, storage and access (spec-inbound-channels D9)."
  use Custyard.DataCase, async: true

  import Custyard.Factory

  alias Custyard.{Attachments, MessageAttachment, Repo}
  alias Custyard.Attachments.StubClient

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3>>

  setup do
    org = insert_organization()
    conv = insert_conversation(organization_id: org.id)
    message = insert_message(conversation_id: conv.id)
    %{org: org, conv: conv, message: message}
  end

  defp descriptor(overrides \\ %{}) do
    url = StubClient.unique_url()

    Map.merge(
      %{filename: "photo.png", content_type: "image/png", size: nil, content_id: nil, url: url},
      overrides
    )
  end

  describe "fetch_for_message/3" do
    test "stores the bytes content-addressed and records the sniffed type", %{message: message} do
      d = descriptor()
      StubClient.put(d.url, @png)

      assert {:ok, [row]} = Attachments.fetch_for_message(message, [d])

      sha = :crypto.hash(:sha256, @png) |> Base.encode16(case: :lower)
      assert %MessageAttachment{state: :fetched, sha256: ^sha, filename: "photo.png"} = row
      assert row.sniffed_type == "image/png"
      assert row.content_type == "image/png"
      assert row.size == byte_size(@png)
      assert row.storage_path == Path.join(binary_part(sha, 0, 2), sha)
      assert File.read!(Attachments.file_path(row)) == @png
      assert String.starts_with?(Attachments.file_path(row), Attachments.dir())
    end

    test "never stores the signed URL", %{message: message} do
      d = descriptor()
      StubClient.put(d.url, "hello")

      assert {:ok, [row]} = Attachments.fetch_for_message(message, [d])
      refute inspect(row) =~ "storage.lettermint.test"
      refute inspect(Repo.all(MessageAttachment)) =~ "signed"
    end

    test "identical content is written once and shared", %{message: message} do
      [a, b] = [descriptor(%{filename: "a.txt"}), descriptor(%{filename: "b.txt"})]
      StubClient.put(a.url, "same bytes")
      StubClient.put(b.url, "same bytes")

      assert {:ok, [ra, rb]} = Attachments.fetch_for_message(message, [a, b])
      assert ra.storage_path == rb.storage_path
      assert File.exists?(Attachments.file_path(ra))
    end

    test "a declared size past the cap is listed as skipped without a fetch", %{message: message} do
      big = descriptor(%{filename: "video.mov", size: 50 * 1_048_576})
      small = descriptor(%{filename: "note.txt", size: 5})
      StubClient.put(small.url, "hello")

      assert {:ok, [skipped, fetched]} = Attachments.fetch_for_message(message, [big, small])
      assert %{state: :skipped, skip_reason: "over_limit", size: 52_428_800} = skipped
      assert fetched.state == :fetched
    end

    test "a body larger than declared is abandoned as too_large", %{message: message} do
      d = descriptor(%{size: 10})
      StubClient.put(d.url, String.duplicate("x", 2_000))

      assert {:ok, [row]} = Attachments.fetch_for_message(message, [d], limit_bytes: 1_000)
      assert %{state: :skipped, skip_reason: "too_large"} = row
      assert row.storage_path == nil
    end

    test "the cap is cumulative across a message's attachments", %{message: message} do
      [a, b] = [descriptor(%{size: 600}), descriptor(%{size: 600})]
      StubClient.put(a.url, String.duplicate("a", 600))
      StubClient.put(b.url, String.duplicate("b", 600))

      assert {:ok, [first, second]} =
               Attachments.fetch_for_message(message, [a, b], limit_bytes: 1_000)

      assert first.state == :fetched
      assert %{state: :skipped, skip_reason: "over_limit"} = second
    end

    test "a zero cap disables fetching", %{message: message} do
      assert {:ok, [row]} = Attachments.fetch_for_message(message, [descriptor()], limit_bytes: 0)
      assert %{state: :skipped, skip_reason: "disabled"} = row
    end

    test "suspect mail is listed, never fetched", %{message: message} do
      d = descriptor(%{filename: "invoice.exe"})
      StubClient.put(d.url, "MZ...")

      assert {:ok, [row]} = Attachments.fetch_for_message(message, [d], skip: "suspect")
      assert %{state: :skipped, skip_reason: "suspect", filename: "invoice.exe"} = row
      refute Attachments.file_path(row)
    end

    test "a failed download is recorded, not raised", %{message: message} do
      d = descriptor()
      StubClient.fail(d.url, :timeout)

      assert {:ok, [row]} = Attachments.fetch_for_message(message, [d])
      assert %{state: :failed, skip_reason: "fetch_failed"} = row
    end

    test "a hostile filename is display data only", %{message: message} do
      d = descriptor(%{filename: "../../etc/passwd\"\n"})
      StubClient.put(d.url, "x")

      assert {:ok, [row]} = Attachments.fetch_for_message(message, [d])
      assert row.filename == ".._.._etc_passwd"
      refute String.contains?(row.storage_path, "..")
    end
  end

  describe "get_for_operator/2" do
    setup %{message: message} do
      d = descriptor()
      StubClient.put(d.url, "secret bytes")
      {:ok, [fetched]} = Attachments.fetch_for_message(message, [d])
      {:ok, [skipped]} = Attachments.fetch_for_message(message, [descriptor()], limit_bytes: 0)
      %{fetched: fetched, skipped: skipped}
    end

    test "a super admin reaches any fetched attachment", %{fetched: fetched} do
      operator = insert_operator_account(role: "super_admin")
      assert %MessageAttachment{id: id} = Attachments.get_for_operator(fetched.id, operator)
      assert id == fetched.id
    end

    test "an agent reaches only their organization's attachments", %{
      fetched: fetched,
      org: org
    } do
      agent = insert_operator_account(role: "agent", organization_id: org.id)
      assert Attachments.get_for_operator(fetched.id, agent)

      other_org = insert_organization()
      stranger = insert_operator_account(role: "agent", organization_id: other_org.id)
      refute Attachments.get_for_operator(fetched.id, stranger)
    end

    test "unfetched and unknown attachments are nil", %{skipped: skipped} do
      operator = insert_operator_account(role: "super_admin")
      refute Attachments.get_for_operator(skipped.id, operator)
      refute Attachments.get_for_operator(skipped.id + 10_000, operator)
    end
  end

  describe "sweep_orphan_files/0" do
    test "removes files no row references and keeps the rest", %{message: message} do
      kept = descriptor()
      StubClient.put(kept.url, "kept-#{System.unique_integer()}")
      {:ok, [kept_row]} = Attachments.fetch_for_message(message, [kept])

      orphan_sha =
        :crypto.hash(:sha256, "orphan-#{System.unique_integer()}") |> Base.encode16(case: :lower)

      orphan_path = Path.join([Attachments.dir(), binary_part(orphan_sha, 0, 2), orphan_sha])
      File.mkdir_p!(Path.dirname(orphan_path))
      File.write!(orphan_path, "orphan")

      assert Attachments.sweep_orphan_files() >= 1
      refute File.exists?(orphan_path)
      assert File.exists?(Attachments.file_path(kept_row))
    end
  end

  test "format_bytes/1" do
    assert Attachments.format_bytes(nil) == ""
    assert Attachments.format_bytes(512) == "512 B"
    assert Attachments.format_bytes(2048) == "2.0 KB"
    assert Attachments.format_bytes(3 * 1_048_576) == "3.0 MB"
  end
end
