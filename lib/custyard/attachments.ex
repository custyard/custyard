defmodule Custyard.Attachments do
  @moduledoc """
  Inbound email attachments (spec-inbound-channels D9).

  The provider delivers each attachment as a signed URL. After the message is
  stored, `fetch_for_message/3` walks the descriptors in order, fetches each
  within the channel's per-message cap into a content-addressed file under
  the attachment directory and records a `Custyard.MessageAttachment` row.
  Attachments past the cap are listed as skipped so the staff knows they
  existed. The signed URL is never persisted and never logged.

  Files are tenant scoped and named by SHA-256 (`<dir>/<tenant>/<ab>/<sha256>`), so a declared
  filename can never become a path and identical content is stored once.
  Serving goes through `CustyardWeb.Staff.AttachmentController`, which
  checks the staff's access to the thread; the directory is never
  a static path.
  """

  import Ecto.Query

  alias Custyard.{Thread, Message, MessageAttachment, Repo, Scope}
  alias Custyard.Attachments.{Client, Sniffer}

  require Logger

  @default_limit_mb 10
  @megabyte 1_048_576

  @doc "The configured attachment directory."
  def dir, do: Application.fetch_env!(:custyard, :attachment_dir)

  @doc "Default per-message cap in bytes for integrations without an email channel."
  def default_limit_bytes, do: @default_limit_mb * @megabyte

  @doc "Per-message cap in bytes for a channel (nil channel: the default)."
  def limit_bytes(nil), do: default_limit_bytes()
  def limit_bytes(%{attachment_limit_mb: mb}) when is_integer(mb), do: mb * @megabyte

  @doc "Attachment rows for a message, in fetch order."
  def list_for_message(message_id) when is_integer(message_id) do
    Repo.all(from a in MessageAttachment, where: a.message_id == ^message_id, order_by: a.id)
  end

  @doc """
  Fetch and record the attachments described by `descriptors` for `message`.

  Each descriptor is a map with `:filename`, `:content_type`, `:size`,
  `:content_id` and `:url` (the signed URL). Options:

    * `:limit_bytes` - per-message cap; `0` records every attachment as
      skipped with reason `disabled` (default: `default_limit_bytes/0`)
    * `:skip` - a skip reason (`"suspect"`) that records every attachment
      without fetching, for mail the staff has not yet trusted

  Returns `{:ok, rows}`. Failed and unfinished slots resume on delivery replay;
  fetched slots are reused. URLs are never retained. The dispatcher withholds
  successful acknowledgment while any slot remains failed or pending.
  """
  def fetch_for_message(%Message{id: message_id, tenant_id: tenant_id}, descriptors, opts \\ [])
      when is_list(descriptors) do
    limit = Keyword.get(opts, :limit_bytes, default_limit_bytes())
    skip = Keyword.get(opts, :skip)

    # A replay resumes each durable slot rather than treating one row as proof
    # that the whole batch finished. The lock also serializes concurrent replays.
    :global.trans({{__MODULE__, message_id}, self()}, fn ->
      reserve_slots(message_id, tenant_id, descriptors)

      case claim_batch(message_id) do
        {:ok, batch_token} ->
          try do
            slots = Enum.zip(list_for_message(message_id), descriptors)

            used =
              Enum.reduce(slots, 0, fn
                {%{state: :fetched, size: size}, _descriptor}, total -> total + (size || 0)
                _slot, total -> total
              end)

            _result =
              Enum.reduce_while(slots, used, &process_slot(&1, &2, limit, skip, batch_token))
          after
            release_batch(message_id, batch_token)
          end

          {:ok, list_for_message(message_id)}

        :busy ->
          {:ok, list_for_message(message_id)}

        :empty ->
          {:ok, []}
      end
    end)
  end

  defp process_slot({row, descriptor}, used, limit, skip, batch_token) do
    if renew_batch(row.message_id, batch_token) do
      process_owned_slot(row, descriptor, used, limit, skip, batch_token)
    else
      {:halt, used}
    end
  end

  defp process_owned_slot(row, descriptor, used, limit, skip, batch_token) do
    if reusable?(row, skip) do
      {:cont, used}
    else
      case claim_slot(row) do
        {:ok, claimed} ->
          {attrs, used} = safe_process_descriptor(descriptor, used, limit, skip)
          persist_result(claimed, attrs, batch_token)
          {:cont, used}

        :busy ->
          {:halt, used}
      end
    end
  end

  defp claim_batch(message_id) do
    now = now()
    token = Ecto.UUID.generate()

    query =
      from a in MessageAttachment,
        where:
          a.message_id == ^message_id and a.position == 0 and
            (is_nil(a.batch_processing_expires_at) or a.batch_processing_expires_at < ^now)

    case Repo.update_all(query,
           set: [
             batch_processing_token: token,
             batch_processing_expires_at: DateTime.add(now, 300)
           ]
         ) do
      {1, _} -> {:ok, token}
      {0, _} -> if list_for_message(message_id) == [], do: :empty, else: :busy
    end
  end

  defp renew_batch(message_id, token) do
    query =
      from a in MessageAttachment,
        where:
          a.message_id == ^message_id and a.position == 0 and a.batch_processing_token == ^token

    case Repo.update_all(query, set: [batch_processing_expires_at: DateTime.add(now(), 300)]) do
      {1, _} -> true
      {0, _} -> false
    end
  end

  defp release_batch(message_id, token) do
    query =
      from a in MessageAttachment,
        where:
          a.message_id == ^message_id and a.position == 0 and a.batch_processing_token == ^token

    Repo.update_all(query, set: [batch_processing_token: nil, batch_processing_expires_at: nil])
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp reusable?(%{state: :fetched}, _skip), do: true

  defp reusable?(%{state: :skipped, skip_reason: reason}, skip),
    do: reason != "suspect" or skip == "suspect"

  defp reusable?(_row, _skip), do: false

  defp reserve_slots(message_id, tenant_id, descriptors) do
    Repo.transaction(fn ->
      existing = list_for_message(message_id)

      if existing != [] and length(existing) != length(descriptors),
        do: Repo.rollback(:attachment_manifest_changed)

      descriptors
      |> Enum.with_index()
      |> Enum.map(fn {descriptor, position} ->
        base =
          descriptor_attrs(message_id, descriptor)
          |> Map.put(:position, position)
          |> Map.put(:tenant_id, tenant_id)

        fingerprint = descriptor_fingerprint(base)
        base = Map.put(base, :descriptor_hash, fingerprint)

        %MessageAttachment{}
        |> MessageAttachment.changeset(Map.put(base, :state, :pending))
        |> Repo.insert!(on_conflict: :nothing, conflict_target: [:message_id, :position])

        row = Repo.get_by!(MessageAttachment, message_id: message_id, position: position)

        if valid_manifest_slot?(row, base, fingerprint) do
          row =
            if is_nil(row.descriptor_hash),
              do: row |> Ecto.Changeset.change(descriptor_hash: fingerprint) |> Repo.update!(),
              else: row

          {row, descriptor}
        else
          Repo.rollback(:attachment_manifest_changed)
        end
      end)
    end)
    |> case do
      {:ok, slots} -> slots
      {:error, reason} -> raise "Attachment reservation failed: #{inspect(reason)}"
    end
  end

  defp valid_manifest_slot?(%{descriptor_hash: hash}, _base, fingerprint) when is_binary(hash),
    do: hash == fingerprint

  defp valid_manifest_slot?(row, base, _fingerprint) do
    fields =
      if row.state == :fetched,
        do: [:filename, :content_type, :content_id],
        else: [:filename, :content_type, :content_id, :size]

    Enum.all?(fields, &(Map.get(row, &1) == Map.get(base, &1)))
  end

  defp descriptor_fingerprint(attrs) do
    attrs
    |> Map.take([:filename, :content_type, :content_id, :size])
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp safe_process_descriptor(descriptor, used, limit, skip) do
    process_descriptor(descriptor, used, limit, skip)
  rescue
    # Provider errors may embed signed URLs. Only a fixed reason is retained.
    _error -> {%{state: :failed, skip_reason: "fetch_failed"}, used}
  catch
    _kind, _reason -> {%{state: :failed, skip_reason: "fetch_failed"}, used}
  end

  defp persist_result(row, %{downloaded: bytes}, batch_token) do
    sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    query = owned_slot_query(row, batch_token)

    # Publish the reference before the file. SQLite's immediate transaction in the
    # sweeper then orders deletion before this reservation or sees the reference.
    case Repo.update_all(query, set: [sha256: sha]) do
      {1, _} ->
        file_lock({row.tenant_id, sha}, fn ->
          finish_slot(row, store(row.tenant_id, bytes), batch_token)
        end)

      {0, _} ->
        Repo.get!(MessageAttachment, row.id)
    end
  end

  defp persist_result(row, attrs, batch_token), do: finish_slot(row, attrs, batch_token)

  # Database leases protect claims across independent BEAM instances too. A
  # crashed worker leaves a resumable slot; fencing prevents an expired worker
  # from overwriting the result of a subsequent claim.
  defp claim_slot(row) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    token = Ecto.UUID.generate()
    expires = DateTime.add(now, 300, :second)

    query =
      from a in MessageAttachment,
        where:
          a.id == ^row.id and a.state != :fetched and
            (is_nil(a.processing_expires_at) or a.processing_expires_at < ^now)

    case Repo.update_all(query,
           set: [processing_token: token, processing_expires_at: expires, state: :pending]
         ) do
      {1, _} -> {:ok, %{row | processing_token: token}}
      {0, _} -> :busy
    end
  end

  defp finish_slot(row, attrs, batch_token) do
    changes =
      Map.merge(attrs, %{
        processing_token: nil,
        processing_expires_at: nil,
        updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    query = owned_slot_query(row, batch_token)

    Repo.update_all(query, set: Map.to_list(changes))
    Repo.get!(MessageAttachment, row.id)
  end

  defp owned_slot_query(row, batch_token) do
    now = now()

    batch =
      from b in MessageAttachment,
        where:
          b.message_id == ^row.message_id and b.position == 0 and
            b.batch_processing_token == ^batch_token and b.batch_processing_expires_at >= ^now,
        select: 1

    from a in MessageAttachment,
      where:
        a.id == ^row.id and a.processing_token == ^row.processing_token and
          exists(subquery(batch))
  end

  defp file_lock(sha, fun), do: :global.trans({{__MODULE__, :file, sha}, self()}, fun)

  defp process_descriptor(_descriptor, used, _limit, skip) when is_binary(skip),
    do: {skipped(skip), used}

  defp process_descriptor(_descriptor, used, 0, _skip), do: {skipped("disabled"), used}

  defp process_descriptor(descriptor, used, _limit, _skip) when not is_map(descriptor) do
    {skipped("invalid_descriptor"), used}
  end

  # Mail read from a mailbox (IMAP, LMTP) carries the decoded bytes itself;
  # the same cumulative cap applies, with no network fetch.
  defp process_descriptor(%{content: bytes}, used, limit, _skip) when is_binary(bytes) do
    if byte_size(bytes) + used > limit,
      do: {skipped("over_limit"), used},
      else: {%{downloaded: bytes}, used + byte_size(bytes)}
  end

  defp process_descriptor(descriptor, used, limit, skip) when not is_map_key(descriptor, :url),
    do: process_descriptor(Map.put(descriptor, :url, nil), used, limit, skip)

  defp process_descriptor(%{url: url}, used, _limit, _skip) when not is_binary(url),
    do: {skipped("no_url"), used}

  defp process_descriptor(descriptor, used, limit, _skip) do
    declared = declared_size(descriptor)

    if declared + used > limit do
      {skipped("over_limit"), used}
    else
      case Client.client().fetch(descriptor.url, limit - used) do
        {:ok, bytes} when byte_size(bytes) + used > limit ->
          {skipped("too_large"), used}

        {:ok, bytes} ->
          {%{downloaded: bytes}, used + byte_size(bytes)}

        {:error, :too_large} ->
          {skipped("too_large"), used}

        {:error, _reason} ->
          Logger.warning("Attachment fetch failed")
          {%{state: :failed, skip_reason: "fetch_failed"}, used}
      end
    end
  end

  defp declared_size(%{size: size}) when is_integer(size) and size > 0, do: size
  defp declared_size(_descriptor), do: 0

  defp skipped(reason), do: %{state: :skipped, skip_reason: reason}

  # Content-addressed write: the temp file lands next to its final name so the
  # rename is atomic on the same filesystem; identical content is kept once.
  defp store(tenant_id, bytes) do
    sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    relative = Path.join([Integer.to_string(tenant_id), binary_part(sha, 0, 2), sha])
    final = Path.join(dir(), relative)

    unless File.exists?(final) do
      File.mkdir_p!(Path.dirname(final))
      tmp = final <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))
      File.write!(tmp, bytes)
      File.rename!(tmp, final)
    end

    %{
      state: :fetched,
      skip_reason: nil,
      sha256: sha,
      storage_path: relative,
      size: byte_size(bytes),
      sniffed_type: Sniffer.sniff(bytes)
    }
  end

  defp descriptor_attrs(message_id, descriptor) when is_map(descriptor) do
    %{
      message_id: message_id,
      filename: descriptor[:filename] |> bounded_string() |> MessageAttachment.clean_filename(),
      content_type: bounded_string(descriptor[:content_type]),
      content_id: bounded_string(descriptor[:content_id]),
      size: declared_or_nil(descriptor)
    }
  end

  defp descriptor_attrs(message_id, _descriptor), do: %{message_id: message_id}

  defp bounded_string(value) when is_binary(value) do
    if String.valid?(value) and value != "", do: String.slice(value, 0, 255), else: nil
  end

  defp bounded_string(_value), do: nil

  defp declared_or_nil(%{size: size}) when is_integer(size) and size >= 0, do: size
  defp declared_or_nil(_descriptor), do: nil

  @doc "Absolute path of a fetched attachment's file, nil for other states."
  def file_path(%MessageAttachment{
        state: :fetched,
        tenant_id: tenant_id,
        sha256: sha,
        storage_path: path
      })
      when is_integer(tenant_id) and is_binary(sha) and byte_size(sha) == 64 do
    expected = Path.join([Integer.to_string(tenant_id), binary_part(sha, 0, 2), sha])
    if path == expected, do: Path.join(dir(), path), else: nil
  end

  def file_path(%MessageAttachment{}), do: nil

  @doc """
  An attachment the staff may download: fetched, on a message the
  staff's role and organization give access to. `nil` otherwise, so the
  caller answers 404 for missing and foreign attachments alike.
  """
  def get(%Scope{tenant_id: tenant_id} = scope, id) when is_integer(id) do
    if Scope.current_staff(scope) do
      Repo.one(
        from a in MessageAttachment,
          join: m in Message,
          on: m.id == a.message_id,
          join: c in Thread,
          on: c.id == m.thread_id,
          where: a.id == ^id and a.tenant_id == ^tenant_id and m.tenant_id == ^tenant_id,
          where: c.tenant_id == ^tenant_id and a.state == :fetched and is_nil(m.deleted_at),
          where: c.suspect == false,
          select: a
      )
    end
  end

  def get(_, _), do: nil

  @doc """
  An attachment the portal of `organization_id` may download: fetched, on a
  message that is neither an internal note nor deleted, in a thread of
  that organization that is not suspect. `nil` otherwise, so the caller
  answers 404 for missing and foreign attachments alike.
  """
  def get_for_portal(id, organization_id) when is_integer(id) and is_integer(organization_id) do
    from(a in MessageAttachment,
      join: m in Message,
      on: m.id == a.message_id,
      join: c in Thread,
      on: c.id == m.thread_id,
      where:
        a.id == ^id and a.state == :fetched and is_nil(m.deleted_at) and
          m.is_internal_note == false and c.suspect == false and
          c.organization_id == ^organization_id
    )
    |> Repo.one()
  end

  @doc """
  Set `:attachments` on portal messages to the downloadable ones, in
  position order: fetched files on messages that are not deleted, and none
  at all while the thread is suspect. Mirrors `get_for_portal/2`.
  """
  def preload_for_portal(messages, %Thread{suspect: true}),
    do: Enum.map(messages, &%{&1 | attachments: []})

  def preload_for_portal(messages, %Thread{}) do
    query = from(a in MessageAttachment, where: a.state == :fetched, order_by: a.position)

    messages
    |> Repo.preload(attachments: query)
    |> Enum.map(fn
      %Message{deleted_at: nil} = message -> message
      message -> %{message | attachments: []}
    end)
  end

  @doc """
  Delete files in the attachment directory that no row references any more
  (their messages were swept or hard-deleted). Returns the count removed.
  """
  def sweep_orphan_files do
    directory = dir()

    if File.dir?(directory) do
      directory
      |> Path.join("*/*/*")
      |> Path.wildcard()
      |> Enum.filter(fn path ->
        parts = path |> Path.relative_to(directory) |> Path.split()

        match?([_, _, _], parts) and Regex.match?(~r/^[0-9]+$/, hd(parts)) and
          Regex.match?(~r/^[0-9a-f]{64}$/, Path.basename(path))
      end)
      |> Enum.reduce(0, fn path, count ->
        sha = Path.basename(path)
        relative = Path.relative_to(path, directory)
        tenant_id = relative |> Path.split() |> hd() |> String.to_integer()

        removed =
          file_lock({tenant_id, sha}, fn ->
            # Check each file immediately before removal, under the same lock as
            # publication. Never remove an in-progress temporary file.
            {:ok, result} =
              Repo.transaction(
                fn ->
                  referenced? =
                    Repo.exists?(
                      from a in MessageAttachment,
                        where: a.tenant_id == ^tenant_id and a.sha256 == ^sha
                    )

                  if not referenced? and old_file?(path), do: File.rm(path), else: :kept
                end,
                mode: :immediate
              )

            result
          end)

        if removed == :ok, do: count + 1, else: count
      end)
    else
      0
    end
  end

  # Leave a full day for another database transaction/process to publish its
  # reference, and for interrupted filesystem writes to be investigated.
  defp old_file?(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> System.os_time(:second) - mtime >= 86_400
      _other -> false
    end
  end

  @doc "Human-readable size."
  def format_bytes(nil), do: ""
  def format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  def format_bytes(bytes) when bytes < @megabyte, do: "#{Float.round(bytes / 1024, 1)} KB"
  def format_bytes(bytes), do: "#{Float.round(bytes / @megabyte, 1)} MB"
end
