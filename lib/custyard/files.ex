defmodule Custyard.Files do
  @moduledoc """
  File content kept in the application database.

  Attachments and logos used to sit on a disk volume, which tied the app to
  one machine. Stored here they go wherever the database goes, including a
  remote libSQL database (Turso, Bunny) reached over HTTP. A local SQLite
  install uses the same tables.

  A file is a `StoredFile` row and its content in `Chunk` rows of
  `chunk_bytes/0` each. The remote servers force the chunking: they refuse a
  single bound blob of a few megabytes and cap a response at about 10 MB,
  and blobs travel base64 in JSON.

  Writing holds no transaction, because a remote write transaction must not
  span an upload: SQLite has one writer. `put/4` inserts the row unpublished
  (`completed_at` nil), inserts each chunk as its own statement, then
  publishes by setting `completed_at`. A partial unique index admits one
  published file per `(tenant_id, kind, key)`, so of two writers racing on a
  key one publishes and the other removes its own rows. Readers never see an
  unpublished row; `sweep_incomplete/1` removes those a crashed writer left.

  Files belong to a tenant. Identical content under the same key is stored
  once per tenant and never shared between tenants. The store does not
  interpret keys: callers decide what they mean.

  Nothing here logs, so keys, hashes and content stay out of the logs.
  """

  import Ecto.Query

  alias Custyard.Files.{Chunk, CorruptError, StoredFile}
  alias Custyard.Repo

  @type kind :: :attachment | :logo

  @kinds [:attachment, :logo]
  @chunk_bytes 262_144
  # Chunks fetched per query: about 1 MiB of content in one response.
  @read_batch 4
  @sweep_after 3600

  @doc "Bytes of content in one chunk. The last chunk of a file may be shorter."
  @spec chunk_bytes() :: pos_integer
  def chunk_bytes, do: @chunk_bytes

  @doc """
  Stores `bytes` as the tenant's file `key` of `kind`.

  When the key already holds the same content, returns that file and writes
  nothing. `{:error, :conflict}` means the key holds different content;
  `{:error, :invalid_key}` means the key is not 1 to 255 letters, digits,
  `.`, `_` or `-`, starting with a letter or digit. Zero bytes is a valid
  file. Database errors raise, after the rows written so far are removed.

  Inside a caller's transaction the chunks join that transaction, so keep
  large writes out of one on a remote database.
  """
  @spec put(tenant_id :: integer, kind, key :: String.t(), bytes :: binary) ::
          {:ok, StoredFile.t()} | {:error, :conflict | :invalid_key}
  def put(tenant_id, kind, key, bytes), do: put(tenant_id, kind, key, bytes, [])

  # Test seam. `:before_publish` is called with the unpublished file once its
  # chunks are written, which is where another writer can win the key.
  @doc false
  def put(tenant_id, kind, key, bytes, opts)
      when is_integer(tenant_id) and kind in @kinds and is_binary(bytes) do
    if valid_key?(key) do
      size = byte_size(bytes)

      store(
        %StoredFile{
          tenant_id: tenant_id,
          kind: kind,
          key: key,
          sha256: sha256(bytes),
          size: size,
          chunk_count: div(size + @chunk_bytes - 1, @chunk_bytes)
        },
        bytes,
        Keyword.get(opts, :before_publish, fn _file -> :ok end)
      )
    else
      {:error, :invalid_key}
    end
  end

  @doc "The tenant's published file for `key`, without its content, or nil."
  @spec get(tenant_id :: integer, kind, key :: String.t()) :: StoredFile.t() | nil
  def get(tenant_id, kind, key)
      when is_integer(tenant_id) and kind in @kinds and is_binary(key) do
    Repo.one(from f in published(kind, key), where: f.tenant_id == ^tenant_id)
  end

  @doc """
  The published file for `key` under any tenant, without its content, or nil.

  For paths served without a session, where the key itself is the secret (a
  logo's UUID). Never use it for a key a client could guess.
  """
  @spec get_public(kind, key :: String.t()) :: StoredFile.t() | nil
  def get_public(kind, key) when kind in @kinds and is_binary(key) do
    Repo.one(from f in published(kind, key), order_by: f.id, limit: 1)
  end

  @doc """
  The whole content of a file.

  `{:error, :corrupt}` when a chunk is missing or the content does not have
  the size and SHA-256 the row records.
  """
  @spec read(StoredFile.t()) :: {:ok, binary} | {:error, :corrupt}
  def read(%StoredFile{} = file) do
    content = file |> stream() |> Enum.to_list() |> IO.iodata_to_binary()

    if byte_size(content) == file.size and sha256(content) == file.sha256,
      do: {:ok, content},
      else: {:error, :corrupt}
  rescue
    CorruptError -> {:error, :corrupt}
  end

  @doc """
  The content of a file as a lazy enumerable of binaries of at most 1 MiB,
  each fetched when the consumer asks for it, so a large download is never
  in memory at once.

  Raises `Custyard.Files.CorruptError` on reaching a missing chunk. The
  SHA-256 is not checked: by the end the content has already been sent.
  """
  @spec stream(StoredFile.t()) :: Enumerable.t()
  def stream(%StoredFile{id: id, chunk_count: count}) do
    Stream.map(0..(count - 1)//@read_batch, fn first ->
      wanted = min(@read_batch, count - first)

      data =
        Repo.all(
          from c in Chunk,
            where: c.file_id == ^id and c.position >= ^first and c.position < ^(first + wanted),
            order_by: c.position,
            select: c.data
        )

      if length(data) == wanted,
        do: IO.iodata_to_binary(data),
        else: raise(CorruptError, file_id: id)
    end)
  end

  @doc "Removes the tenant's published file for `key` and its content, if there is one."
  @spec delete(tenant_id :: integer, kind, key :: String.t()) :: :ok
  def delete(tenant_id, kind, key)
      when is_integer(tenant_id) and kind in @kinds and is_binary(key) do
    files = from f in published(kind, key), where: f.tenant_id == ^tenant_id

    # Together or not at all: a published row without its chunks would pass
    # for the file, and a later put of the same content would keep it.
    {:ok, _} =
      Repo.transaction(fn ->
        Repo.delete_all(from c in Chunk, where: c.file_id in subquery(select(files, [f], f.id)))
        Repo.delete_all(files)
      end)

    :ok
  end

  @doc """
  Removes files whose writer never published them, with their chunks, and
  returns how many.

  Options: `:older_than`, the age in seconds past which an unpublished file
  counts as abandoned (default #{@sweep_after}; a write still running at
  that age fails), and `:now`, the clock.
  """
  @spec sweep_incomplete(keyword) :: non_neg_integer
  def sweep_incomplete(opts \\ []) do
    age = Keyword.get(opts, :older_than, @sweep_after)

    cutoff =
      opts
      |> Keyword.get_lazy(:now, &DateTime.utc_now/0)
      |> DateTime.add(-age, :second)
      |> DateTime.truncate(:second)

    from(f in StoredFile,
      where: is_nil(f.completed_at) and f.inserted_at < ^cutoff,
      select: f.id
    )
    |> Repo.all()
    |> Enum.count(&discard/1)
  end

  defp published(kind, key) do
    from f in StoredFile,
      where: f.kind == ^kind and f.key == ^key and not is_nil(f.completed_at)
  end

  defp valid_key?(key),
    do: is_binary(key) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]{0,254}\z/, key)

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp store(%StoredFile{} = new, bytes, before_publish) do
    case get(new.tenant_id, new.kind, new.key) do
      nil ->
        write(new, bytes, before_publish)

      %StoredFile{sha256: sha256, size: size} = file
      when sha256 == new.sha256 and size == new.size ->
        {:ok, file}

      %StoredFile{} ->
        {:error, :conflict}
    end
  end

  defp write(new, bytes, before_publish) do
    file = Repo.insert!(new)

    published =
      try do
        write_chunks(file, bytes)
        before_publish.(file)
        publish(file)
      catch
        kind, reason ->
          discard_quietly(file.id)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    case published do
      {:ok, file} ->
        {:ok, file}

      # Another writer published the key first, so its file answers the call.
      {:error, _changeset} ->
        discard(file.id)
        store(new, bytes, before_publish)
    end
  end

  # One statement per chunk, each committed on its own.
  defp write_chunks(%StoredFile{id: id, size: size, chunk_count: count}, bytes) do
    Enum.each(0..(count - 1)//1, fn position ->
      offset = position * @chunk_bytes
      data = binary_part(bytes, offset, min(@chunk_bytes, size - offset))
      Repo.insert!(%Chunk{file_id: id, position: position, data: data})
    end)
  end

  defp publish(file) do
    file
    |> Ecto.Changeset.change(completed_at: DateTime.utc_now(:second))
    |> Ecto.Changeset.unique_constraint([:tenant_id, :kind, :key])
    |> Repo.update()
  end

  # Removes a file that was never published. The row goes first, and only
  # while it is still unpublished, so a file published in the meantime keeps
  # its chunks. The foreign key takes the chunks with the row; the second
  # delete is for a connection that runs with foreign keys off.
  defp discard(id) do
    {removed, _} =
      Repo.delete_all(from f in StoredFile, where: f.id == ^id and is_nil(f.completed_at))

    if removed == 1, do: Repo.delete_all(from c in Chunk, where: c.file_id == ^id)
    removed == 1
  end

  # The write already failed and its error is the one to report. Whatever
  # this leaves behind, sweep_incomplete/1 removes.
  defp discard_quietly(id) do
    discard(id)
  catch
    _kind, _reason -> false
  end
end

defmodule Custyard.Files.CorruptError do
  @moduledoc """
  Raised while streaming a stored file when one of its chunks is missing, and
  by a download when the content does not add up to the recorded size.
  """
  defexception [:file_id]

  @impl true
  def message(%{file_id: id}), do: "stored file #{id} is missing chunks"
end
