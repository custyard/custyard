defmodule Custyard.FilesTest do
  use Custyard.DataCase, async: true

  import Custyard.Factory

  alias Custyard.Files
  alias Custyard.Files.{Chunk, CorruptError, StoredFile}

  @chunk Files.chunk_bytes()
  @mib 1_048_576

  setup do
    %{tenant: insert_tenant()}
  end

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp chunks(file_id), do: Repo.aggregate(from(c in Chunk, where: c.file_id == ^file_id), :count)

  # Positions and byte lengths, read without loading the content.
  defp layout(file_id) do
    Repo.all(
      from c in Chunk,
        where: c.file_id == ^file_id,
        order_by: c.position,
        select: {c.position, fragment("length(?)", c.data)}
    )
  end

  defp drop_chunk(file_id, position) do
    Repo.delete_all(from c in Chunk, where: c.file_id == ^file_id and c.position == ^position)
  end

  # A row as a writer leaves it before publishing: chunks written, no completed_at.
  defp insert_unpublished(tenant, key, bytes, attrs \\ []) do
    file =
      Repo.insert!(
        struct!(
          %StoredFile{
            tenant_id: tenant.id,
            kind: :attachment,
            key: key,
            sha256: sha256(bytes),
            size: byte_size(bytes),
            chunk_count: 1
          },
          attrs
        )
      )

    Repo.insert!(%Chunk{file_id: file.id, position: 0, data: bytes})
    file
  end

  describe "put/4 and read/1" do
    test "round trip of a small file", %{tenant: tenant} do
      key = "#{Ecto.UUID.generate()}.png"
      bytes = <<137, 80, 78, 71, 13, 10, 26, 10, "logo">>

      assert {:ok, %StoredFile{} = file} = Files.put(tenant.id, :logo, key, bytes)
      assert file.tenant_id == tenant.id
      assert file.kind == :logo
      assert file.key == key
      assert file.sha256 == sha256(bytes)
      assert file.size == byte_size(bytes)
      assert file.chunk_count == 1
      assert %DateTime{} = file.completed_at

      assert Files.get(tenant.id, :logo, key).id == file.id
      assert Files.read(file) == {:ok, bytes}
      assert layout(file.id) == [{0, byte_size(bytes)}]
    end

    test "content with a ragged tail is split into full chunks and a remainder", %{tenant: tenant} do
      bytes = :crypto.strong_rand_bytes(700_013)

      assert {:ok, file} = Files.put(tenant.id, :attachment, sha256(bytes), bytes)
      assert file.chunk_count == 3
      assert layout(file.id) == [{0, @chunk}, {1, @chunk}, {2, 700_013 - 2 * @chunk}]
      assert Files.read(file) == {:ok, bytes}
    end

    test "content that is an exact multiple of the chunk size has no short chunk", %{
      tenant: tenant
    } do
      bytes = :crypto.strong_rand_bytes(3 * @chunk)

      assert {:ok, file} = Files.put(tenant.id, :attachment, sha256(bytes), bytes)
      assert file.chunk_count == 3
      assert layout(file.id) == [{0, @chunk}, {1, @chunk}, {2, @chunk}]
      assert Files.read(file) == {:ok, bytes}
    end

    # A remote database carries text and blobs differently, and a chunk
    # boundary can fall inside a multi-byte character.
    test "text, NUL bytes and invalid UTF-8 come back byte for byte", %{tenant: tenant} do
      contents = %{
        "ascii" => "plain text\n",
        "utf8" => String.duplicate("Gr\u00FC\u00DFe, \u4E16\u754C\n", 40_000),
        "nul" => :binary.copy(<<0>>, @chunk + 1),
        "invalid" => :binary.copy(<<0xFF, 0xFE, 0x00, 0xC3>>, 100_000)
      }

      assert String.valid?(contents["utf8"])
      refute String.valid?(contents["invalid"])

      for {key, bytes} <- contents do
        assert {:ok, file} = Files.put(tenant.id, :attachment, key, bytes)
        assert file.sha256 == sha256(bytes)
        assert Files.read(file) == {:ok, bytes}
        assert file |> Files.stream() |> Enum.join() == bytes
      end
    end

    test "zero bytes is a file with no chunks", %{tenant: tenant} do
      assert {:ok, file} = Files.put(tenant.id, :attachment, "empty", "")
      assert file.size == 0
      assert file.chunk_count == 0
      assert file.sha256 == sha256("")
      assert chunks(file.id) == 0

      assert Files.read(file) == {:ok, ""}
      assert Enum.to_list(Files.stream(file)) == []
      assert {:ok, %StoredFile{id: id}} = Files.put(tenant.id, :attachment, "empty", "")
      assert id == file.id
    end

    # Larger than the single blob and the response a libSQL server accepts.
    @tag timeout: 180_000
    test "content past the remote server's blob and response limits", %{tenant: tenant} do
      bytes = :crypto.strong_rand_bytes(12 * @mib + 4097)

      assert {:ok, file} = Files.put(tenant.id, :attachment, sha256(bytes), bytes)
      assert file.chunk_count == 49
      assert chunks(file.id) == 49
      assert Files.read(file) == {:ok, bytes}

      parts = Enum.to_list(Files.stream(file))
      assert length(parts) == 13
      assert Enum.all?(parts, &(byte_size(&1) <= @mib))
      assert IO.iodata_to_binary(parts) == bytes
    end

    test "the same content under the same key is stored once", %{tenant: tenant} do
      bytes = :crypto.strong_rand_bytes(@chunk + 100)
      key = sha256(bytes)

      assert {:ok, first} = Files.put(tenant.id, :attachment, key, bytes)
      assert {:ok, second} = Files.put(tenant.id, :attachment, key, bytes)

      assert second.id == first.id
      assert second.completed_at == first.completed_at
      assert Repo.aggregate(StoredFile, :count) == 1
      assert Repo.aggregate(Chunk, :count) == 2
    end

    test "different content under a taken key is a conflict", %{tenant: tenant} do
      assert {:ok, file} = Files.put(tenant.id, :logo, "logo.png", "first")

      assert Files.put(tenant.id, :logo, "logo.png", "other") == {:error, :conflict}
      assert Files.put(tenant.id, :logo, "logo.png", "first, longer") == {:error, :conflict}

      assert Files.read(file) == {:ok, "first"}
      assert Repo.aggregate(StoredFile, :count) == 1
      assert Repo.aggregate(Chunk, :count) == 1
    end

    test "keys are plain names", %{tenant: tenant} do
      invalid = [
        "",
        ".hidden",
        "-flag",
        "_x",
        "a/b",
        "../x",
        "a b",
        "a\n",
        "a\0b",
        "caf\u00E9",
        String.duplicate("a", 256),
        nil,
        :key
      ]

      for key <- invalid do
        assert Files.put(tenant.id, :attachment, key, "x") == {:error, :invalid_key}
      end

      assert Repo.aggregate(StoredFile, :count) == 0

      for key <- ["a", "0", "A1._-", "#{Ecto.UUID.generate()}.svg", String.duplicate("a", 255)] do
        assert {:ok, %StoredFile{key: ^key}} = Files.put(tenant.id, :attachment, key, "x")
      end
    end

    test "an unknown tenant raises and stores nothing" do
      assert_raise Ecto.ConstraintError, fn -> Files.put(-1, :logo, "logo.png", "x") end

      assert Repo.aggregate(StoredFile, :count) == 0
      assert Repo.aggregate(Chunk, :count) == 0
    end

    test "inside a caller's transaction", %{tenant: tenant} do
      bytes = :crypto.strong_rand_bytes(2 * @chunk + 1)

      assert {:ok, {:ok, file}} =
               Repo.transaction(fn -> Files.put(tenant.id, :attachment, "kept", bytes) end)

      assert Files.read(file) == {:ok, bytes}

      assert {:error, :undone} =
               Repo.transaction(fn ->
                 {:ok, _file} = Files.put(tenant.id, :attachment, "undone", bytes)
                 Repo.rollback(:undone)
               end)

      assert Files.get(tenant.id, :attachment, "undone") == nil
      assert Repo.aggregate(Chunk, :count) == 3
    end
  end

  describe "tenants" do
    test "the same key under two tenants is two files", %{tenant: tenant} do
      other = insert_tenant()
      bystander = insert_tenant()
      key = sha256("shared key")

      assert {:ok, mine} = Files.put(tenant.id, :attachment, key, "mine")
      assert {:ok, theirs} = Files.put(other.id, :attachment, key, "theirs")
      assert mine.id != theirs.id

      assert Files.get(tenant.id, :attachment, key).id == mine.id
      assert Files.get(other.id, :attachment, key).id == theirs.id
      assert Files.get(bystander.id, :attachment, key) == nil
      assert Files.get(tenant.id, :logo, key) == nil

      assert Files.read(mine) == {:ok, "mine"}
      assert Files.read(theirs) == {:ok, "theirs"}
    end

    test "identical content is not shared between tenants", %{tenant: tenant} do
      other = insert_tenant()
      bytes = :crypto.strong_rand_bytes(@chunk + 1)
      key = sha256(bytes)

      assert {:ok, mine} = Files.put(tenant.id, :attachment, key, bytes)
      assert {:ok, theirs} = Files.put(other.id, :attachment, key, bytes)
      assert mine.id != theirs.id
      assert chunks(mine.id) == 2
      assert chunks(theirs.id) == 2

      assert Files.delete(tenant.id, :attachment, key) == :ok
      assert Files.read(theirs) == {:ok, bytes}
    end

    test "deleting a tenant removes its files and their chunks", %{tenant: tenant} do
      other = insert_tenant()
      assert {:ok, gone} = Files.put(other.id, :attachment, "gone", "content")
      assert {:ok, kept} = Files.put(tenant.id, :attachment, "kept", "content")

      Repo.delete!(other)

      assert Repo.get(StoredFile, gone.id) == nil
      assert chunks(gone.id) == 0
      assert Files.read(kept) == {:ok, "content"}
    end
  end

  describe "get_public/2" do
    test "finds a published file by kind and key alone", %{tenant: tenant} do
      key = "#{Ecto.UUID.generate()}.png"
      assert {:ok, file} = Files.put(tenant.id, :logo, key, "logo")

      assert Files.get_public(:logo, key).id == file.id
      assert Files.get_public(:attachment, key) == nil
      assert Files.get_public(:logo, "#{Ecto.UUID.generate()}.png") == nil
    end
  end

  describe "stream/1" do
    test "yields the content in pieces of at most 1 MiB", %{tenant: tenant} do
      bytes = :crypto.strong_rand_bytes(2 * @mib + div(@mib, 2) + 7)
      assert {:ok, file} = Files.put(tenant.id, :attachment, sha256(bytes), bytes)
      assert file.chunk_count == 11

      parts = Enum.to_list(Files.stream(file))
      assert Enum.map(parts, &byte_size/1) == [@mib, @mib, div(@mib, 2) + 7]
      assert IO.iodata_to_binary(parts) == bytes
    end

    test "fetches a piece only when it is asked for, and raises on a missing chunk", %{
      tenant: tenant
    } do
      bytes = :crypto.strong_rand_bytes(9 * @chunk)
      assert {:ok, file} = Files.put(tenant.id, :attachment, sha256(bytes), bytes)
      drop_chunk(file.id, 8)

      stream = Files.stream(file)
      assert stream |> Enum.take(2) |> IO.iodata_to_binary() == binary_part(bytes, 0, 2 * @mib)

      error = assert_raise CorruptError, fn -> Enum.to_list(stream) end
      assert error.file_id == file.id
      refute Exception.message(error) =~ file.key
    end
  end

  describe "read/1" do
    setup %{tenant: tenant} do
      bytes = :crypto.strong_rand_bytes(5 * @chunk + 9)
      {:ok, file} = Files.put(tenant.id, :attachment, sha256(bytes), bytes)
      %{stored: file}
    end

    test "is corrupt when a chunk was changed", %{stored: file} do
      Repo.update_all(
        from(c in Chunk, where: c.file_id == ^file.id and c.position == 4),
        set: [data: :binary.copy(<<1>>, @chunk)]
      )

      assert layout(file.id) |> Enum.at(4) == {4, @chunk}
      assert Files.read(file) == {:error, :corrupt}
    end

    test "is corrupt when the content has the wrong size", %{stored: file} do
      Repo.update_all(
        from(c in Chunk, where: c.file_id == ^file.id and c.position == 5),
        set: [data: "short"]
      )

      assert Files.read(file) == {:error, :corrupt}
    end

    test "is corrupt when a chunk is missing", %{stored: file} do
      drop_chunk(file.id, 2)
      assert Files.read(file) == {:error, :corrupt}

      drop_chunk(file.id, 5)
      assert Files.read(file) == {:error, :corrupt}
    end
  end

  describe "delete/3" do
    test "removes the file and its chunks, and only that file", %{tenant: tenant} do
      other = insert_tenant()
      bytes = :crypto.strong_rand_bytes(2 * @chunk + 1)
      assert {:ok, file} = Files.put(tenant.id, :attachment, "doomed", bytes)
      assert {:ok, sibling} = Files.put(tenant.id, :attachment, "sibling", bytes)
      assert {:ok, foreign} = Files.put(other.id, :attachment, "doomed", bytes)
      pending = insert_unpublished(tenant, "doomed", "still being written")

      assert Files.delete(tenant.id, :attachment, "doomed") == :ok

      assert Files.get(tenant.id, :attachment, "doomed") == nil
      assert Repo.get(StoredFile, file.id) == nil
      assert chunks(file.id) == 0

      assert Files.read(sibling) == {:ok, bytes}
      assert Files.read(foreign) == {:ok, bytes}
      assert Repo.get(StoredFile, pending.id)
      assert chunks(pending.id) == 1
    end

    test "is fine when there is nothing to remove", %{tenant: tenant} do
      assert Files.delete(tenant.id, :attachment, "absent") == :ok

      assert {:ok, _file} = Files.put(tenant.id, :logo, "logo.png", "logo")
      assert Files.delete(tenant.id, :logo, "logo.png") == :ok
      assert Files.delete(tenant.id, :logo, "logo.png") == :ok
    end

    test "frees the key for other content", %{tenant: tenant} do
      assert {:ok, _file} = Files.put(tenant.id, :logo, "logo.png", "first")
      assert Files.delete(tenant.id, :logo, "logo.png") == :ok
      assert {:ok, file} = Files.put(tenant.id, :logo, "logo.png", "second")
      assert Files.read(file) == {:ok, "second"}
    end
  end

  describe "unpublished rows" do
    test "are invisible and do not block a put of the same key", %{tenant: tenant} do
      pending = insert_unpublished(tenant, "contested", "abandoned")
      insert_unpublished(tenant, "contested-2", "abandoned")

      assert Files.get(tenant.id, :attachment, "contested") == nil
      assert Files.get_public(:attachment, "contested") == nil

      assert {:ok, file} = Files.put(tenant.id, :attachment, "contested", "published")
      assert file.id != pending.id
      assert Files.get(tenant.id, :attachment, "contested").id == file.id
      assert Files.get_public(:attachment, "contested").id == file.id
      assert Files.read(file) == {:ok, "published"}

      # A put of the very content the abandoned row claims still writes its own.
      assert {:ok, same} = Files.put(tenant.id, :attachment, "contested-2", "abandoned")
      assert same.id not in [pending.id, file.id]
      assert Files.read(same) == {:ok, "abandoned"}
    end

    test "sweep_incomplete/1 removes only those past the age", %{tenant: tenant} do
      now = ~U[2026-11-12 12:00:00Z]
      stale = insert_unpublished(tenant, "stale", "a", inserted_at: ~U[2026-11-12 10:59:59Z])
      recent = insert_unpublished(tenant, "recent", "b", inserted_at: ~U[2026-11-12 11:00:01Z])
      assert {:ok, published} = Files.put(tenant.id, :attachment, "published", "c")

      Repo.update_all(from(f in StoredFile, where: f.id == ^published.id),
        set: [inserted_at: ~U[2026-11-01 00:00:00Z]]
      )

      assert Files.sweep_incomplete(now: now) == 1
      assert Repo.get(StoredFile, stale.id) == nil
      assert chunks(stale.id) == 0
      assert Repo.get(StoredFile, recent.id)
      assert chunks(recent.id) == 1
      assert Files.read(published) == {:ok, "c"}

      assert Files.sweep_incomplete(now: now) == 0
      assert Files.sweep_incomplete(now: now, older_than: 3599) == 0
      assert Files.sweep_incomplete(now: now, older_than: 3598) == 1
      assert Repo.get(StoredFile, recent.id) == nil
      assert chunks(recent.id) == 0
      assert Files.read(published) == {:ok, "c"}
    end

    test "sweep_incomplete/1 leaves a write in progress alone by default", %{tenant: tenant} do
      pending = insert_unpublished(tenant, "uploading", "a")

      assert Files.sweep_incomplete() == 0
      assert Repo.get(StoredFile, pending.id)
    end
  end

  describe "publishing" do
    # The hook runs where another writer, on this machine or another, can
    # publish the key after this one found it free.
    test "a writer that loses the race returns the winner and leaves nothing behind", %{
      tenant: tenant
    } do
      bytes = :crypto.strong_rand_bytes(@chunk + 5)

      rival = fn loser ->
        assert loser.completed_at == nil
        assert chunks(loser.id) == 2
        assert {:ok, winner} = Files.put(tenant.id, :attachment, "raced", bytes)
        send(self(), {:raced, winner, loser})
      end

      assert {:ok, file} =
               Files.put(tenant.id, :attachment, "raced", bytes, before_publish: rival)

      assert_received {:raced, winner, loser}

      assert file.id == winner.id
      assert file.id != loser.id
      assert Repo.get(StoredFile, loser.id) == nil
      assert chunks(loser.id) == 0
      assert Repo.aggregate(StoredFile, :count) == 1
      assert Repo.aggregate(Chunk, :count) == 2
      assert Files.read(file) == {:ok, bytes}
    end

    test "a writer that loses the race to different content gets a conflict", %{tenant: tenant} do
      rival = fn loser ->
        assert {:ok, winner} = Files.put(tenant.id, :logo, "logo.png", "theirs")
        send(self(), {:raced, winner, loser})
      end

      assert Files.put(tenant.id, :logo, "logo.png", "mine", before_publish: rival) ==
               {:error, :conflict}

      assert_received {:raced, winner, loser}
      assert Repo.get(StoredFile, loser.id) == nil
      assert chunks(loser.id) == 0
      assert Repo.aggregate(StoredFile, :count) == 1
      assert Files.read(winner) == {:ok, "theirs"}
    end

    test "losing the race inside a caller's transaction keeps the transaction usable", %{
      tenant: tenant
    } do
      rival = fn _loser -> {:ok, _winner} = Files.put(tenant.id, :logo, "logo.png", "same") end

      assert {:ok, file} =
               Repo.transaction(fn ->
                 {:ok, file} =
                   Files.put(tenant.id, :logo, "logo.png", "same", before_publish: rival)

                 {:ok, _other} = Files.put(tenant.id, :logo, "after.png", "after")
                 file
               end)

      assert Files.read(file) == {:ok, "same"}
      assert Files.get(tenant.id, :logo, "after.png")
      assert Repo.aggregate(StoredFile, :count) == 2
      assert Repo.aggregate(Chunk, :count) == 2
    end

    test "a write that raises removes its rows and reraises", %{tenant: tenant} do
      bytes = :crypto.strong_rand_bytes(@chunk + 5)

      assert_raise RuntimeError, "interrupted", fn ->
        Files.put(tenant.id, :attachment, "failing", bytes,
          before_publish: fn _file -> raise "interrupted" end
        )
      end

      assert catch_exit(
               Files.put(tenant.id, :attachment, "failing", bytes,
                 before_publish: fn _file -> exit(:killed) end
               )
             ) == :killed

      assert Files.get(tenant.id, :attachment, "failing") == nil
      assert Repo.aggregate(StoredFile, :count) == 0
      assert Repo.aggregate(Chunk, :count) == 0

      assert {:ok, file} = Files.put(tenant.id, :attachment, "failing", bytes)
      assert Files.read(file) == {:ok, bytes}
    end
  end
end
