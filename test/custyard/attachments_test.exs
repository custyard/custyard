defmodule Custyard.AttachmentsTest do
  @moduledoc "Attachment fetching, storage and access (spec-inbound-channels D9)."
  use Custyard.DataCase, async: true

  import Custyard.Factory

  alias Custyard.{Attachments, MessageAttachment, Repo}
  alias Custyard.Attachments.StubClient

  defp scope(staff),
    do: Custyard.Scope.for_staff(staff, Custyard.Tenants.get_tenant!(staff.tenant_id))

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

      assert row.storage_path ==
               Path.join([Integer.to_string(message.tenant_id), binary_part(sha, 0, 2), sha])

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

    test "a replay resumes failed slots without duplicating successful attachments", %{
      message: message
    } do
      first = descriptor()
      second = descriptor()
      StubClient.put(first.url, "first")
      StubClient.fail(second.url, :timeout)
      assert {:ok, [a, b]} = Attachments.fetch_for_message(message, [first, second])
      assert b.state == :failed
      StubClient.put(second.url, "second")
      assert {:ok, [again_a, again_b]} = Attachments.fetch_for_message(message, [first, second])
      assert again_a.id == a.id
      assert again_b.id == b.id
      assert again_b.state == :fetched
      assert length(Attachments.list_for_message(message.id)) == 2
    end

    test "unfinished durable slots resume after interruption", %{message: message} do
      pending =
        Repo.insert!(%MessageAttachment{
          tenant_id: message.tenant_id,
          message_id: message.id,
          position: 0,
          state: :pending,
          filename: "photo.png",
          content_type: "image/png"
        })

      d = descriptor()
      StubClient.put(d.url, "resumed")
      assert {:ok, [resumed]} = Attachments.fetch_for_message(message, [d])
      assert resumed.id == pending.id
      assert resumed.state == :fetched
    end

    test "retries account for fetched bytes in later manifest positions", %{message: message} do
      first = descriptor(%{size: 600})
      second = descriptor(%{filename: "second.txt", size: 600})
      StubClient.fail(first.url, :timeout)
      StubClient.put(second.url, String.duplicate("b", 600))

      assert {:ok, [%{state: :failed}, %{state: :fetched} = fetched]} =
               Attachments.fetch_for_message(message, [first, second], limit_bytes: 1_000)

      StubClient.put(first.url, String.duplicate("a", 600))

      assert {:ok, [skipped, preserved]} =
               Attachments.fetch_for_message(message, [first, second], limit_bytes: 1_000)

      assert skipped.state == :skipped
      assert skipped.skip_reason == "over_limit"
      assert preserved.id == fetched.id
      assert preserved.size == 600
    end

    test "another process's batch lease blocks work and an expired batch resumes", %{
      message: message
    } do
      first = descriptor(%{size: 600})
      second = descriptor(%{filename: "second.txt", size: 600})
      StubClient.fail(first.url, :timeout)
      StubClient.put(second.url, String.duplicate("b", 600))

      assert {:ok, [failed, fetched]} =
               Attachments.fetch_for_message(message, [first, second], limit_bytes: 1_000)

      expires = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(300)

      failed
      |> Ecto.Changeset.change(
        batch_processing_token: "another-worker",
        batch_processing_expires_at: expires
      )
      |> Repo.update!()

      StubClient.put(first.url, String.duplicate("a", 600))

      assert {:ok, [%{state: :failed}, preserved]} =
               Attachments.fetch_for_message(message, [first, second], limit_bytes: 1_000)

      assert preserved.id == fetched.id
      assert Repo.get!(MessageAttachment, failed.id).batch_processing_token == "another-worker"

      Repo.get!(MessageAttachment, failed.id)
      |> Ecto.Changeset.change(batch_processing_expires_at: DateTime.add(expires, -301))
      |> Repo.update!()

      assert {:ok, [%{state: :skipped, skip_reason: "over_limit"}, _fetched]} =
               Attachments.fetch_for_message(message, [first, second], limit_bytes: 1_000)
    end

    test "a worker that loses its batch cannot publish bytes or clear the new owner", %{
      message: message
    } do
      first = descriptor()
      second = descriptor(%{filename: "second.txt"})

      StubClient.on_fetch(first.url, fn _max ->
        row = Repo.get_by!(MessageAttachment, message_id: message.id, position: 0)
        row |> Ecto.Changeset.change(batch_processing_token: "new-owner") |> Repo.update!()
        {:ok, "stale bytes"}
      end)

      StubClient.put(second.url, "should not fetch")
      assert {:ok, [unfinished, later]} = Attachments.fetch_for_message(message, [first, second])
      assert unfinished.state == :pending
      assert unfinished.sha256 == nil
      assert unfinished.batch_processing_token == "new-owner"
      assert later.state == :pending
    end

    test "active claims block work until expiry and expired claims resume", %{message: message} do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      pending =
        Repo.insert!(%MessageAttachment{
          tenant_id: message.tenant_id,
          message_id: message.id,
          position: 0,
          state: :pending,
          filename: "photo.png",
          content_type: "image/png",
          processing_token: "interrupted",
          processing_expires_at: DateTime.add(now, 300)
        })

      d = descriptor()
      StubClient.put(d.url, "resumed")
      assert {:ok, [%{state: :pending}]} = Attachments.fetch_for_message(message, [d])

      pending
      |> Ecto.Changeset.change(processing_expires_at: DateTime.add(now, -1))
      |> Repo.update!()

      assert {:ok, [resumed]} = Attachments.fetch_for_message(message, [d])
      assert resumed.state == :fetched
      assert resumed.processing_token == nil
    end

    test "a busy early slot still returns later unfinished manifest entries", %{message: message} do
      first = descriptor()
      second = descriptor(%{filename: "second.txt"})
      expires = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(300)

      Repo.insert!(%MessageAttachment{
        tenant_id: message.tenant_id,
        message_id: message.id,
        position: 0,
        filename: first.filename,
        content_type: first.content_type,
        state: :pending,
        processing_token: "active",
        processing_expires_at: expires
      })

      Repo.insert!(%MessageAttachment{
        tenant_id: message.tenant_id,
        message_id: message.id,
        position: 1,
        filename: second.filename,
        content_type: second.content_type,
        state: :failed,
        skip_reason: "fetch_failed"
      })

      StubClient.put(second.url, "must wait for first slot")
      assert {:ok, [busy, unfinished]} = Attachments.fetch_for_message(message, [first, second])
      assert busy.state == :pending
      assert unfinished.state == :failed
      assert unfinished.position == 1
    end

    test "concurrent replays share the same attachment slots", %{message: message} do
      d = descriptor()
      StubClient.put(d.url, "concurrent")
      first = Task.async(fn -> Attachments.fetch_for_message(message, [d]) end)
      second = Task.async(fn -> Attachments.fetch_for_message(message, [d]) end)
      assert {:ok, [one]} = Task.await(first)
      assert {:ok, [two]} = Task.await(second)
      assert one.id == two.id
      assert length(Attachments.list_for_message(message.id)) == 1
    end

    test "changed and truncated replay manifests cannot silently complete work", %{
      message: message
    } do
      first = descriptor()
      second = descriptor()
      StubClient.put(first.url, "one")
      StubClient.fail(second.url, :timeout)
      assert {:ok, _rows} = Attachments.fetch_for_message(message, [first, second])

      assert_raise RuntimeError, ~r/attachment_manifest_changed/, fn ->
        Attachments.fetch_for_message(message, [first])
      end

      assert_raise RuntimeError, ~r/attachment_manifest_changed/, fn ->
        Attachments.fetch_for_message(message, [first, %{second | filename: "different.txt"}])
      end

      assert length(Attachments.list_for_message(message.id)) == 2
    end

    test "suspect slots can be fetched after trust using fresh descriptors", %{message: message} do
      original = descriptor()
      assert {:ok, [row]} = Attachments.fetch_for_message(message, [original], skip: "suspect")
      fresh = descriptor()
      StubClient.put(fresh.url, "trusted")
      assert {:ok, [fetched]} = Attachments.fetch_for_message(message, [fresh])
      assert fetched.id == row.id
      assert fetched.state == :fetched
      assert fetched.skip_reason == nil
    end

    test "invalid descriptor metadata cannot prevent the rest of a batch", %{message: message} do
      long =
        descriptor(%{
          filename: 42,
          content_type: String.duplicate("x", 300),
          content_id: String.duplicate("y", 300)
        })

      valid = descriptor()
      StubClient.put(long.url, "one")
      StubClient.put(valid.url, "two")

      assert {:ok, [invalid, bounded, fetched]} =
               Attachments.fetch_for_message(message, [nil, long, valid])

      assert invalid.skip_reason == "invalid_descriptor"
      assert String.length(bounded.content_type) == 255
      assert String.length(bounded.content_id) == 255
      assert fetched.state == :fetched
    end

    test "a hostile filename is display data only", %{message: message} do
      d = descriptor(%{filename: "../../etc/passwd\"\n"})
      StubClient.put(d.url, "x")

      assert {:ok, [row]} = Attachments.fetch_for_message(message, [d])
      assert row.filename == ".._.._etc_passwd"
      refute String.contains?(row.storage_path, "..")
    end
  end

  describe "get/2" do
    setup %{message: message} do
      d = descriptor()
      StubClient.put(d.url, "secret bytes")
      {:ok, [fetched]} = Attachments.fetch_for_message(message, [d])
      other_message = insert_message(conversation_id: message.conversation_id)

      {:ok, [skipped]} =
        Attachments.fetch_for_message(other_message, [descriptor()], limit_bytes: 0)

      %{fetched: fetched, skipped: skipped}
    end

    test "a tenant admin reaches its fetched attachments", %{fetched: fetched} do
      staff = insert_staff_account(role: "admin")
      assert %MessageAttachment{id: id} = Attachments.get(scope(staff), fetched.id)
      assert id == fetched.id
    end

    test "an agent reaches only their tenant attachments", %{
      fetched: fetched,
      org: org
    } do
      agent = insert_staff_account(role: "agent", organization_id: org.id)
      assert Attachments.get(scope(agent), fetched.id)

      other_tenant = insert_tenant()
      stranger = insert_staff_account(role: "agent", tenant_id: other_tenant.id)
      refute Attachments.get(scope(stranger), fetched.id)
    end

    test "marking the conversation suspect blocks already fetched files", %{
      fetched: fetched,
      conv: conv
    } do
      staff = insert_staff_account(role: "admin")
      conv |> Ecto.Changeset.change(suspect: true) |> Repo.update!()
      refute Attachments.get(scope(staff), fetched.id)
    end

    test "stale, removed and suspended staff scopes cannot read attachments", %{fetched: fetched} do
      staff = insert_staff_account(role: "admin")
      original_scope = scope(staff)
      assert Attachments.get(original_scope, fetched.id)
      Repo.update!(Ecto.Changeset.change(staff, role: "agent"))
      refute Attachments.get(original_scope, fetched.id)
      current = Repo.reload!(staff)
      current_scope = scope(current)
      Repo.delete!(current)
      refute Attachments.get(current_scope, fetched.id)
      active = insert_staff_account(role: "agent")
      active_scope = scope(active)
      tenant = Custyard.Tenants.get_tenant!(active.tenant_id)
      Repo.update!(Ecto.Changeset.change(tenant, status: "suspended"))
      refute Attachments.get(active_scope, fetched.id)
    end

    test "unfetched and unknown attachments are nil", %{skipped: skipped} do
      staff = insert_staff_account(role: "admin")
      refute Attachments.get(scope(staff), skipped.id)
      refute Attachments.get(scope(staff), skipped.id + 10_000)
    end
  end

  describe "sweep_orphan_files/0" do
    test "removes files no row references and keeps the rest", %{message: message} do
      kept = descriptor()
      StubClient.put(kept.url, "kept-#{System.unique_integer()}")
      {:ok, [kept_row]} = Attachments.fetch_for_message(message, [kept])

      orphan_sha =
        :crypto.hash(:sha256, "orphan-#{System.unique_integer()}") |> Base.encode16(case: :lower)

      orphan_path =
        Path.join([
          Attachments.dir(),
          Integer.to_string(message.tenant_id),
          binary_part(orphan_sha, 0, 2),
          orphan_sha
        ])

      File.mkdir_p!(Path.dirname(orphan_path))
      File.write!(orphan_path, "orphan")
      File.touch!(orphan_path, System.os_time(:second) - 90_000)

      assert Attachments.sweep_orphan_files() >= 1
      refute File.exists?(orphan_path)
      assert File.exists?(Attachments.file_path(kept_row))
    end
  end

  test "orphan cleanup leaves fresh final files and temporary writes alone", %{message: message} do
    sha = :crypto.hash(:sha256, "fresh-#{System.unique_integer()}") |> Base.encode16(case: :lower)

    path =
      Path.join([
        Attachments.dir(),
        Integer.to_string(message.tenant_id),
        binary_part(sha, 0, 2),
        sha
      ])

    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "fresh")
    temporary = path <> ".tmp-123"
    File.write!(temporary, "in progress")
    File.touch!(temporary, System.os_time(:second) - 90_000)
    Attachments.sweep_orphan_files()
    assert File.exists?(path)
    assert File.exists?(temporary)
  end

  test "format_bytes/1" do
    assert Attachments.format_bytes(nil) == ""
    assert Attachments.format_bytes(512) == "512 B"
    assert Attachments.format_bytes(2048) == "2.0 KB"
    assert Attachments.format_bytes(3 * 1_048_576) == "3.0 MB"
  end
end
