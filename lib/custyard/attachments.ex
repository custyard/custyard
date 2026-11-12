defmodule Custyard.Attachments do
  @moduledoc """
  Inbound email attachments (spec-inbound-channels D9).

  The provider delivers each attachment as a signed URL. After the message is
  stored, `fetch_for_message/3` walks the descriptors in order, fetches each
  within the channel's per-message cap, stores the content in the database
  through `Custyard.Files` and records a `Custyard.MessageAttachment` row.
  Attachments past the cap are listed as skipped so the staff knows they
  existed. The signed URL is never persisted and never logged.

  Content belongs to a tenant and is keyed by its SHA-256, so a declared
  filename never names anything in storage, identical content is stored once
  per tenant and no tenant shares content with another. A row points at its
  content by `sha256` alone; `stored_file/1` resolves it. Serving goes
  through `CustyardWeb.Staff.AttachmentController` and
  `CustyardWeb.Portal.AttachmentController`, which check access to the
  thread first.
  """

  import Ecto.Query

  alias Custyard.{Files, Message, MessageAttachment, Repo, Scope, Thread}
  alias Custyard.Attachments.{Client, Scanner, Sniffer}
  alias Custyard.Files.StoredFile

  require Custyard.Log, as: Log

  @default_limit_mb 10
  @megabyte 1_048_576
  # Content published less than a day ago is never swept as an orphan. Writers
  # publish their reference first (persist_result/3), so this is margin and
  # not what keeps a concurrent store safe.
  @orphan_grace 86_400
  # A failed scan is retried for a day after the row was stored
  # (retry_failed_scans/1), at most once a minute.
  @scan_retry_window 86_400
  @scan_retry_min_interval 60
  @no_scans %{clean: 0, infected: 0, error: 0, pending: 0}

  @typedoc "Verdict counts of a rescan."
  @type scan_counts :: %{
          clean: non_neg_integer,
          infected: non_neg_integer,
          error: non_neg_integer,
          pending: non_neg_integer
        }

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

    # Publish the reference before the content. The orphan sweep checks for
    # references and deletes inside one immediate transaction, so it either
    # commits before this update, and the content is then stored afresh, or
    # sees the reference and keeps the file (remove_orphan/2).
    case Repo.update_all(query, set: [sha256: sha]) do
      {1, _} -> finish_slot(row, store(row.tenant_id, sha, bytes), batch_token)
      {0, _} -> Repo.get!(MessageAttachment, row.id)
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
          Log.warning(:attachment_fetch_failed)
          {%{state: :failed, skip_reason: "fetch_failed"}, used}
      end
    end
  end

  defp declared_size(%{size: size}) when is_integer(size) and size > 0, do: size
  defp declared_size(_descriptor), do: 0

  defp skipped(reason), do: %{state: :skipped, skip_reason: reason}

  # Content-addressed write: the key is the content's own hash, so the store
  # keeps identical content once per tenant. The scan runs on the bytes in
  # hand, which are the bytes the store just accepted.
  defp store(tenant_id, sha, bytes) do
    case Files.put(tenant_id, :attachment, sha, bytes) do
      {:ok, %StoredFile{}} ->
        :ok

      # The store only refuses a hash as key when the file already under it
      # is some other content. Raising does what any failed write does: the
      # slot stays leased and unfinished, and a replay takes it up again.
      {:error, reason} ->
        raise "attachment content was not stored: #{reason}"
    end

    status = Scanner.scan(bytes)

    %{
      state: :fetched,
      skip_reason: nil,
      sha256: sha,
      size: byte_size(bytes),
      sniffed_type: Sniffer.sniff(bytes),
      scan_status: status,
      scanned_at: scan_time(status)
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

  @doc """
  The stored file that holds a fetched attachment's content, without the
  content: read it with `Custyard.Files.read/1` or `Custyard.Files.stream/1`.

  `nil` for a row in any other state, for one without a SHA-256, and when
  the tenant has no published file with that content.
  """
  @spec stored_file(MessageAttachment.t()) :: StoredFile.t() | nil
  def stored_file(%MessageAttachment{state: :fetched, tenant_id: tenant_id, sha256: sha})
      when is_integer(tenant_id) and is_binary(sha) and byte_size(sha) == 64 do
    case Files.get(tenant_id, :attachment, sha) do
      # The key is the content's hash. A file recorded with a different hash
      # is not this attachment's content, whatever its key says.
      %StoredFile{sha256: ^sha} = file -> file
      _other -> nil
    end
  end

  def stored_file(%MessageAttachment{}), do: nil

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
          where: a.scan_status == :clean,
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
        a.id == ^id and a.state == :fetched and a.scan_status == :clean and is_nil(m.deleted_at) and
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
    # Include quarantined files as visible placeholders; download authorization
    # remains fail-closed in get_for_portal/2 and the download component.
    query = from(a in MessageAttachment, where: a.state == :fetched, order_by: a.position)

    messages
    |> Repo.preload(attachments: query)
    |> Enum.map(fn
      %Message{deleted_at: nil} = message -> message
      message -> %{message | attachments: []}
    end)
  end

  @doc "Only a fetched file with a successful malware scan may leave storage."
  def downloadable?(%MessageAttachment{state: :fetched, scan_status: :clean}), do: true
  def downloadable?(_), do: false

  def scan_label(%MessageAttachment{scan_status: :infected}), do: "Blocked: malware detected"

  def scan_label(%MessageAttachment{scan_status: :error} = attachment) do
    if scan_retry_window?(attachment, DateTime.utc_now()),
      do: "Quarantined: security scan will be retried",
      else: "Quarantined: security scan failed"
  end

  def scan_label(%MessageAttachment{scan_status: :clean}), do: "Security scan passed"
  def scan_label(_), do: "Quarantined: awaiting security scan"

  # Whether retry_failed_scans/1 still takes a failed scan up: a scanner is
  # configured and the row was stored less than a day before `now`.
  defp scan_retry_window?(%MessageAttachment{inserted_at: %DateTime{} = inserted_at}, now),
    do: Scanner.configured?() and DateTime.diff(now, inserted_at) < @scan_retry_window

  defp scan_retry_window?(_attachment, _now), do: false

  @doc "Rescan stored content after an authorized administrator explicitly requests it."
  def rescan_thread(%Scope{role: "admin"} = scope, thread_id) do
    case Scope.current_staff(scope) do
      %{role: "admin"} ->
        case Repo.get_by(Thread, id: thread_id, tenant_id: scope.tenant_id, suspect: false) do
          nil -> {:error, :not_found}
          thread -> {:ok, rescan_query(from(m in Message, where: m.thread_id == ^thread.id))}
        end

      _ ->
        {:error, :unauthorized}
    end
  end

  def rescan_thread(_, _), do: {:error, :unauthorized}

  @doc "Operator release task: scan the content already stored; never assume old content is clean."
  def rescan_all do
    rescan_query(from(m in Message))
  end

  @doc """
  Rescan the attachments whose scan failed and that were stored less than
  a day before `now`, each one only once its backoff has passed. Returns
  verdict counts like `rescan_thread/2`. `Custyard.Attachments.ScanRetry`
  calls it every minute.

  A failed scan is usually a scanner that was not ready: one that scales to
  zero starts on the connection of the scan that then times out. A row is
  due a minute after its last scan, and later once the time since its last
  scan is as long as the row was old at that scan. Retries therefore come
  at about 1, 2, 4, 8 and so on minutes of age, eleven or so in the day.
  Age counts from when the row was stored, never from its last scan: every
  rescan moves that, and a window on it would retry for ever and keep the
  scanner awake. After the day only an explicit rescan remains.

  Rows on deleted messages and in suspect threads are left alone, as by
  `rescan_thread/2` and `rescan_all/0`. Without a configured scanner nothing
  is rescanned: a scan would give `:pending` and replace the failure. Each
  row whose verdict changes refreshes open views of its thread.
  """
  @spec retry_failed_scans(DateTime.t()) :: scan_counts
  def retry_failed_scans(now \\ DateTime.utc_now()) do
    if Scanner.configured?() do
      now = DateTime.truncate(now, :second)

      now
      |> scan_retry_candidates()
      |> Enum.filter(&scan_retry_due?(&1, now))
      |> Enum.reduce(@no_scans, fn candidate, counts ->
        case retry_scan(candidate, now) do
          nil -> counts
          status -> Map.update!(counts, status, &(&1 + 1))
        end
      end)
    else
      @no_scans
    end
  end

  # Failed scans inside the window, where rescan_query/1 would reach them.
  # The backoff needs only these fields and is checked in Elixir.
  defp scan_retry_candidates(now) do
    since = DateTime.add(now, -@scan_retry_window, :second)

    from(a in MessageAttachment,
      join: m in Message,
      on: m.id == a.message_id and m.tenant_id == a.tenant_id,
      join: t in Thread,
      on: t.id == m.thread_id and t.tenant_id == m.tenant_id,
      where: a.state == :fetched and a.scan_status == :error and a.inserted_at > ^since,
      where: is_nil(m.deleted_at) and t.suspect == false,
      order_by: a.id,
      select: %{id: a.id, thread_id: t.id, inserted_at: a.inserted_at, scanned_at: a.scanned_at}
    )
    |> Repo.all()
  end

  defp scan_retry_due?(%{scanned_at: nil}, _now), do: true

  defp scan_retry_due?(%{scanned_at: scanned_at, inserted_at: inserted_at}, now) do
    DateTime.diff(now, scanned_at) >=
      max(@scan_retry_min_interval, DateTime.diff(scanned_at, inserted_at))
  end

  # The candidates are a snapshot. Another instance or an administrator may
  # have rescanned the row since, so it is read again and retried only while
  # it is still a due failure; rescan_row/1 fences any scan that overlaps.
  defp retry_scan(%{id: id, thread_id: thread_id}, now) do
    with %MessageAttachment{scan_status: :error} = row <- Repo.get(MessageAttachment, id),
         true <- scan_retry_due?(row, now) do
      status = rescan_row(row)
      if status != :error, do: broadcast_attachment_change(thread_id)
      status
    else
      _not_due -> nil
    end
  end

  # The staff, portal and prospect thread views reload the messages and
  # their attachments on this message-level event, as Custyard.Threads
  # sends it for a deleted message.
  defp broadcast_attachment_change(thread_id) do
    Phoenix.PubSub.broadcast(
      Custyard.PubSub,
      "thread:#{thread_id}",
      {:message_updated, thread_id}
    )
  end

  defp rescan_query(messages) do
    ids =
      from(a in MessageAttachment,
        join: m in subquery(messages),
        on: m.id == a.message_id and m.tenant_id == a.tenant_id,
        join: t in Thread,
        on: t.id == m.thread_id and t.tenant_id == m.tenant_id,
        where: a.state == :fetched and is_nil(m.deleted_at) and t.suspect == false,
        select: a.id
      )
      |> Repo.all()

    Enum.reduce(ids, @no_scans, fn id, counts ->
      case rescan_row(Repo.get(MessageAttachment, id)) do
        nil -> counts
        status -> Map.update!(counts, status, &(&1 + 1))
      end
    end)
  end

  defp rescan_row(nil), do: nil
  defp rescan_row(%MessageAttachment{scan_status: :infected}), do: :infected

  defp rescan_row(row) do
    # Withdraw any prior clean verdict before starting a new scan. Concurrent
    # download requests must observe quarantine while the verdict is unknown.
    token = Ecto.UUID.generate()

    row =
      row
      |> Ecto.Changeset.change(scan_status: :pending, scanned_at: nil, scan_token: token)
      |> Repo.update!()

    status = scan_stored(row)

    # Fence concurrent rescans: an older scan cannot publish a clean verdict
    # over a newer quarantine or failure.
    {written, _} =
      from(a in MessageAttachment, where: a.id == ^row.id and a.scan_token == ^token)
      |> Repo.update_all(
        set: [scan_status: status, scanned_at: scan_time(status), scan_token: nil]
      )

    current = Repo.get(MessageAttachment, row.id)
    if written == 1 && current, do: current.scan_status, else: :pending
  end

  # A rescan reads the content back from the store. Content that is missing,
  # past the scan bound or no longer the bytes that were stored gets no
  # verdict, only :error, so it stays quarantined.
  defp scan_stored(row) do
    max_bytes = Scanner.max_bytes()

    with %StoredFile{size: size} = file when size <= max_bytes <- stored_file(row),
         {:ok, bytes} <- Files.read(file) do
      Scanner.scan(bytes)
    else
      _unreadable -> :error
    end
  end

  defp scan_time(:pending), do: nil
  defp scan_time(_), do: now()

  @doc """
  Remove stored attachment content that no row references any more (its
  messages were swept or hard-deleted) once it is more than a day old.
  Returns the count removed.
  """
  def sweep_orphan_files do
    cutoff = DateTime.add(now(), -@orphan_grace, :second)

    orphans(cutoff)
    |> select([f], {f.tenant_id, f.key})
    |> Repo.all()
    |> Enum.count(&remove_orphan(&1, cutoff))
  end

  # Published attachment files older than the cutoff that no attachment row
  # of their tenant names. A file still being written has no completed_at and
  # never matches; Custyard.Files.sweep_incomplete/1 removes abandoned ones.
  defp orphans(cutoff) do
    from f in StoredFile,
      as: :file,
      where: f.kind == :attachment and f.completed_at < ^cutoff,
      where:
        not exists(
          from a in MessageAttachment,
            where: a.tenant_id == parent_as(:file).tenant_id and a.sha256 == parent_as(:file).key,
            select: 1
        )
  end

  # The candidate list is a hint, already stale when it arrives. Each file is
  # checked again and removed inside one immediate transaction, which takes
  # SQLite's write lock before it reads. A writer publishes its row's sha256
  # before it stores content (persist_result/3), and that update needs the
  # same lock. So the update either commits first and the check here sees the
  # reference, or it waits until the file is gone and the writer's put, which
  # comes after it, finds nothing to reuse and stores the content again. No
  # lock between processes is needed, and this holds across machines. One
  # short transaction per file keeps the write lock brief.
  defp remove_orphan({tenant_id, key}, cutoff) do
    {:ok, removed?} =
      Repo.transaction(
        fn ->
          orphan? =
            Repo.exists?(
              from f in orphans(cutoff), where: f.tenant_id == ^tenant_id and f.key == ^key
            )

          if orphan?, do: Files.delete(tenant_id, :attachment, key)
          orphan?
        end,
        mode: :immediate
      )

    removed?
  end

  @doc """
  Remove attachment files an earlier release left in the attachment
  directory that no row of their tenant references any more (their messages
  were swept or hard-deleted) once they are a day old. Returns the count
  removed.

  That release kept a fetched attachment at
  `<attachment_dir>/<tenant id>/<first two hex chars of its SHA-256>/<SHA-256>`.
  `Custyard.Files.LegacyImport` copies those files into the database and
  leaves the originals where they are, so erasure and retention reach an
  original only here. A file that some row of its tenant still names is
  kept, imported or not. Only regular files at a path of exactly that shape
  are considered, and a directory that is missing or cannot be read has
  nothing to sweep.

  Options: `:attachment_dir` replaces the configured directory (tests).
  """
  @spec sweep_legacy_files(keyword) :: non_neg_integer
  def sweep_legacy_files(opts \\ []) do
    configured = fn -> Application.get_env(:custyard, :attachment_dir) end

    case Keyword.get_lazy(opts, :attachment_dir, configured) do
      dir when is_binary(dir) and dir != "" -> sweep_legacy_dir(dir)
      _unset -> 0
    end
  end

  # A tenant id as the earlier release wrote it, no leading zero, and at most
  # eighteen digits, which keeps it inside a 64-bit id. A hash sits under its
  # own first two characters.
  defp sweep_legacy_dir(dir) do
    for tenant <- legacy_directories(dir, ~r/\A[1-9][0-9]{0,17}\z/),
        prefix <- legacy_directories(Path.join(dir, tenant), ~r/\A[0-9a-f]{2}\z/),
        sha <- legacy_names(Path.join([dir, tenant, prefix]), ~r/\A[0-9a-f]{64}\z/),
        String.starts_with?(sha, prefix),
        remove_legacy_orphan?(
          String.to_integer(tenant),
          sha,
          Path.join([dir, tenant, prefix, sha])
        ),
        reduce: 0 do
      count -> count + 1
    end
  end

  # lstat, not stat: a symlink is reported as one, so the walk never follows
  # one out of the directory and never removes a file through one.
  defp legacy_directories(dir, pattern) do
    Enum.filter(legacy_names(dir, pattern), fn name ->
      match?({:ok, %File.Stat{type: :directory}}, File.lstat(Path.join(dir, name)))
    end)
  end

  defp legacy_names(dir, pattern) do
    case File.ls(dir) do
      {:ok, names} -> Enum.filter(names, &Regex.match?(pattern, &1))
      {:error, _missing_or_unreadable} -> []
    end
  end

  # Nothing writes these files any more, so no lock spans the check and the
  # removal: a row that appears in between stores its content in the
  # database (store/3) and never reads this file.
  defp remove_legacy_orphan?(tenant_id, sha, path) do
    old_regular_file?(path) and not legacy_referenced?(tenant_id, sha) and File.rm(path) == :ok
  end

  defp old_regular_file?(path) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :regular, mtime: mtime}} ->
        System.os_time(:second) - mtime >= @orphan_grace

      _not_a_file ->
        false
    end
  end

  defp legacy_referenced?(tenant_id, sha) do
    Repo.exists?(
      from a in MessageAttachment, where: a.tenant_id == ^tenant_id and a.sha256 == ^sha
    )
  end

  @doc "Human-readable size."
  def format_bytes(nil), do: ""
  def format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  def format_bytes(bytes) when bytes < @megabyte, do: "#{Float.round(bytes / 1024, 1)} KB"
  def format_bytes(bytes), do: "#{Float.round(bytes / @megabyte, 1)} MB"
end
