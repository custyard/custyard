defmodule Custyard.AttachmentsTest do
  @moduledoc "Attachment fetching, storage and access (spec-inbound-channels D9)."
  use Custyard.DataCase, async: true

  import Custyard.Factory

  alias Custyard.{Attachments, Files, MessageAttachment, Repo}
  alias Custyard.Attachments.StubClient
  alias Custyard.Files.{Chunk, StoredFile}

  defp scope(staff),
    do: Custyard.Scope.for_staff(staff, Custyard.Tenants.get_tenant!(staff.tenant_id))

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3>>

  setup do
    org = insert_organization()
    conv = insert_thread(organization_id: org.id)
    message = insert_message(thread_id: conv.id)
    %{org: org, conv: conv, message: message}
  end

  defp descriptor(overrides \\ %{}) do
    url = StubClient.unique_url()

    Map.merge(
      %{filename: "photo.png", content_type: "image/png", size: nil, content_id: nil, url: url},
      overrides
    )
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp fetched(message, bytes) do
    {:ok, [row]} = Attachments.fetch_for_message(message, [%{filename: "f.bin", content: bytes}])
    row
  end

  # Content in the store that no attachment row names.
  defp unreferenced(tenant_id, bytes) do
    {:ok, file} = Files.put(tenant_id, :attachment, sha256(bytes), bytes)
    file
  end

  defp stored_files(tenant_id),
    do: Repo.all(from f in StoredFile, where: f.tenant_id == ^tenant_id, order_by: f.id)

  defp chunks(file_id), do: Repo.aggregate(from(c in Chunk, where: c.file_id == ^file_id), :count)

  # The orphan sweep goes by when a file was published.
  defp publish_hours_ago(%StoredFile{id: id}, hours) do
    at = DateTime.utc_now(:second) |> DateTime.add(-hours * 3600, :second)
    Repo.update_all(from(f in StoredFile, where: f.id == ^id), set: [completed_at: at])
  end

  describe "fetch_for_message/3" do
    test "stores the bytes content-addressed and records the sniffed type", %{message: message} do
      d = descriptor()
      StubClient.put(d.url, @png)

      assert {:ok, [row]} = Attachments.fetch_for_message(message, [d])

      sha = sha256(@png)
      assert %MessageAttachment{state: :fetched, sha256: ^sha, filename: "photo.png"} = row
      assert row.sniffed_type == "image/png"
      assert row.content_type == "image/png"
      assert row.size == byte_size(@png)

      assert %StoredFile{kind: :attachment, key: ^sha, sha256: ^sha} =
               stored = Attachments.stored_file(row)

      assert stored.tenant_id == message.tenant_id
      assert stored.size == byte_size(@png)
      assert Files.read(stored) == {:ok, @png}
      assert [%StoredFile{id: id}] = stored_files(message.tenant_id)
      assert id == stored.id
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
      assert ra.sha256 == rb.sha256
      assert [%StoredFile{id: id}] = stored_files(message.tenant_id)
      assert Attachments.stored_file(ra).id == id
      assert Attachments.stored_file(rb).id == id
      assert Files.read(Attachments.stored_file(rb)) == {:ok, "same bytes"}
    end

    test "two messages of a tenant with the same content share one stored file", %{
      message: message
    } do
      bytes = :crypto.strong_rand_bytes(Files.chunk_bytes() + 17)
      first = fetched(message, bytes)
      second = fetched(insert_message(thread_id: message.thread_id), bytes)

      assert first.id != second.id
      assert [%StoredFile{id: id, chunk_count: 2}] = stored_files(message.tenant_id)
      assert chunks(id) == 2
      assert Attachments.stored_file(first).id == id
      assert Attachments.stored_file(second).id == id
    end

    test "another tenant's identical content is a file of its own", %{message: message} do
      other = insert_organization(tenant_id: insert_tenant().id)
      theirs = insert_message(thread_id: insert_thread(organization_id: other.id).id)
      bytes = "the same bytes in two tenants"

      mine = Attachments.stored_file(fetched(message, bytes))
      other_file = Attachments.stored_file(fetched(theirs, bytes))

      assert mine.sha256 == other_file.sha256
      assert mine.id != other_file.id
      assert mine.tenant_id == message.tenant_id
      assert other_file.tenant_id == other.tenant_id

      # Removing one tenant's copy leaves the other's whole.
      :ok = Files.delete(mine.tenant_id, :attachment, mine.key)
      assert Files.read(other_file) == {:ok, bytes}
    end

    test "content of several chunks is stored and read back intact", %{message: message} do
      bytes = :crypto.strong_rand_bytes(5 * Files.chunk_bytes() + 4097)
      row = fetched(message, bytes)

      assert row.size == byte_size(bytes)
      assert %StoredFile{chunk_count: 6} = stored = Attachments.stored_file(row)
      assert Files.read(stored) == {:ok, bytes}
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
      assert row.sha256 == nil
      refute Attachments.stored_file(row)
      assert stored_files(message.tenant_id) == []
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
      refute Attachments.stored_file(row)
      assert stored_files(message.tenant_id) == []
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
      assert stored_files(message.tenant_id) == []
    end

    # A hash can only be refused as a key when the file already under it is
    # other content. The row must not then claim content it does not have.
    test "content the store refuses is not recorded as fetched", %{message: message} do
      bytes = "content whose place is taken"
      {:ok, squatter} = Files.put(message.tenant_id, :attachment, sha256(bytes), "other content")

      assert_raise RuntimeError, "attachment content was not stored: conflict", fn ->
        Attachments.fetch_for_message(message, [%{filename: "f.bin", content: bytes}])
      end

      assert [%{state: :pending, batch_processing_token: nil} = row] =
               Attachments.list_for_message(message.id)

      refute Attachments.stored_file(row)
      assert [%StoredFile{id: id}] = stored_files(message.tenant_id)
      assert id == squatter.id
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
      assert Attachments.stored_file(row).key == sha256("x")
    end
  end

  describe "MessageAttachment.changeset/2" do
    test "a fetched attachment needs its hash and size, and no path" do
      attrs = %{tenant_id: 1, message_id: 1, state: :fetched}

      assert %{sha256: ["can't be blank"], size: ["can't be blank"]} =
               errors_on(MessageAttachment.changeset(%MessageAttachment{}, attrs))

      complete = Map.merge(attrs, %{sha256: sha256("x"), size: 1, storage_path: "1/2d/2d71"})
      changeset = MessageAttachment.changeset(%MessageAttachment{}, complete)

      assert changeset.valid?
      refute Map.has_key?(changeset.changes, :storage_path)
    end
  end

  describe "stored_file/1" do
    test "is nil for a row that is not fetched", %{message: message} do
      assert {:ok, [skipped]} =
               Attachments.fetch_for_message(message, [descriptor()], limit_bytes: 0)

      refute Attachments.stored_file(skipped)
      refute Attachments.stored_file(%MessageAttachment{state: :fetched, tenant_id: 1})

      row = fetched(insert_message(thread_id: message.thread_id), "x")
      assert %StoredFile{} = Attachments.stored_file(row)
      refute Attachments.stored_file(%{row | state: :pending})
    end

    test "is nil once the content is gone", %{message: message} do
      row = fetched(message, "here, then not")
      assert %StoredFile{} = Attachments.stored_file(row)

      :ok = Files.delete(row.tenant_id, :attachment, row.sha256)
      refute Attachments.stored_file(row)
    end

    test "is nil while the content is still being written", %{message: message} do
      row = fetched(message, "not published")
      %StoredFile{id: id} = Attachments.stored_file(row)
      Repo.update_all(from(f in StoredFile, where: f.id == ^id), set: [completed_at: nil])

      refute Attachments.stored_file(row)
    end

    test "is nil for a file whose recorded hash is not its key", %{message: message} do
      row = fetched(message, "the real content")
      %StoredFile{id: id} = Attachments.stored_file(row)
      Repo.update_all(from(f in StoredFile, where: f.id == ^id), set: [sha256: sha256("other")])

      refute Attachments.stored_file(row)
    end

    test "never reaches another tenant's content", %{message: message} do
      row = fetched(message, "tenant bound")
      other = insert_tenant()

      refute Attachments.stored_file(%{row | tenant_id: other.id})
    end
  end

  describe "get/2" do
    setup %{message: message} do
      d = descriptor()
      StubClient.put(d.url, "secret bytes")
      {:ok, [fetched]} = Attachments.fetch_for_message(message, [d])
      other_message = insert_message(thread_id: message.thread_id)

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

    test "marking the thread suspect blocks already fetched files", %{
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
    test "removes old content no row references, chunks included, and keeps the rest", %{
      message: message
    } do
      tenant_id = message.tenant_id
      kept_row = fetched(message, "referenced")
      kept = Attachments.stored_file(kept_row)
      orphan = unreferenced(tenant_id, :crypto.strong_rand_bytes(2 * Files.chunk_bytes() + 5))
      young = unreferenced(tenant_id, "stored a moment ago")
      {:ok, logo} = Files.put(tenant_id, :logo, "logo.png", @png)

      assert chunks(orphan.id) == 3
      Enum.each([kept, orphan, logo], &publish_hours_ago(&1, 25))
      publish_hours_ago(young, 23)

      assert Attachments.sweep_orphan_files() == 1

      refute Repo.get(StoredFile, orphan.id)
      assert chunks(orphan.id) == 0
      assert Repo.aggregate(Chunk, :count) == chunks(kept.id) + chunks(young.id) + chunks(logo.id)

      assert Files.read(Attachments.stored_file(kept_row)) == {:ok, "referenced"}
      assert Files.read(Repo.get!(StoredFile, young.id)) == {:ok, "stored a moment ago"}
      assert Files.read(Repo.get!(StoredFile, logo.id)) == {:ok, @png}
      assert Attachments.sweep_orphan_files() == 0
    end

    test "content becomes an orphan when its last row goes", %{message: message} do
      bytes = "attached to two messages"
      first = fetched(message, bytes)
      second = fetched(insert_message(thread_id: message.thread_id), bytes)
      file = Attachments.stored_file(first)
      publish_hours_ago(file, 48)

      Repo.delete!(first)
      assert Attachments.sweep_orphan_files() == 0
      assert Files.read(Attachments.stored_file(second)) == {:ok, bytes}

      Repo.delete!(second)
      assert Attachments.sweep_orphan_files() == 1
      refute Repo.get(StoredFile, file.id)
      assert chunks(file.id) == 0
    end

    # A writer sets its row's sha256 before it stores the content, and the
    # sweep relies on that: the hash alone must protect the file, whatever
    # state the row is in.
    test "a row that has only published its hash keeps the content", %{message: message} do
      bytes = "reference first, content second"
      file = unreferenced(message.tenant_id, bytes)
      publish_hours_ago(file, 48)

      Repo.insert!(%MessageAttachment{
        tenant_id: message.tenant_id,
        message_id: message.id,
        position: 0,
        state: :pending,
        sha256: sha256(bytes)
      })

      assert Attachments.sweep_orphan_files() == 0
      assert Files.read(Repo.get!(StoredFile, file.id)) == {:ok, bytes}
    end

    test "a reference in another tenant does not keep this tenant's content", %{message: message} do
      bytes = "the same bytes in two tenants"
      other = insert_organization(tenant_id: insert_tenant().id)

      theirs =
        fetched(insert_message(thread_id: insert_thread(organization_id: other.id).id), bytes)

      mine = unreferenced(message.tenant_id, bytes)
      Enum.each([mine, Attachments.stored_file(theirs)], &publish_hours_ago(&1, 48))

      assert Attachments.sweep_orphan_files() == 1
      refute Repo.get(StoredFile, mine.id)
      assert Files.read(Attachments.stored_file(theirs)) == {:ok, bytes}
    end

    # Writes that were never published are Files.sweep_incomplete/1's to remove.
    test "leaves a write that was never published alone", %{message: message} do
      old = DateTime.utc_now(:second) |> DateTime.add(-48 * 3600, :second)

      unpublished =
        Repo.insert!(%StoredFile{
          tenant_id: message.tenant_id,
          kind: :attachment,
          key: sha256("in progress"),
          sha256: sha256("in progress"),
          size: 11,
          chunk_count: 1,
          inserted_at: old
        })

      Repo.insert!(%Chunk{file_id: unpublished.id, position: 0, data: "in progress"})

      assert Attachments.sweep_orphan_files() == 0
      assert Repo.get(StoredFile, unpublished.id)
      assert chunks(unpublished.id) == 1
    end

    test "content swept as an orphan is stored again by a later fetch", %{message: message} do
      bytes = "gone and back"
      first = fetched(message, bytes)
      publish_hours_ago(Attachments.stored_file(first), 48)
      Repo.delete!(first)
      assert Attachments.sweep_orphan_files() == 1
      assert stored_files(message.tenant_id) == []

      again = fetched(insert_message(thread_id: message.thread_id), bytes)
      assert Files.read(Attachments.stored_file(again)) == {:ok, bytes}
    end
  end

  test "format_bytes/1" do
    assert Attachments.format_bytes(nil) == ""
    assert Attachments.format_bytes(512) == "512 B"
    assert Attachments.format_bytes(2048) == "2.0 KB"
    assert Attachments.format_bytes(3 * 1_048_576) == "3.0 MB"
  end
end
