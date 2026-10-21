defmodule Custyard.Attachments do
  @moduledoc """
  Inbound email attachments (spec-inbound-channels D9).

  The provider delivers each attachment as a signed URL. After the message is
  stored, `fetch_for_message/3` walks the descriptors in order, fetches each
  within the channel's per-message cap into a content-addressed file under
  the attachment directory and records a `Custyard.MessageAttachment` row.
  Attachments past the cap are listed as skipped so the operator knows they
  existed. The signed URL is never persisted and never logged.

  Files are named by their SHA-256 (`<dir>/<ab>/<sha256>`), so a declared
  filename can never become a path and identical content is stored once.
  Serving goes through `CustyardWeb.Operator.AttachmentController`, which
  checks the operator's access to the conversation; the directory is never
  a static path.
  """

  import Ecto.Query

  alias Custyard.{Authorization, Conversation, Message, MessageAttachment, Repo}
  alias Custyard.Attachments.{Client, Sniffer}

  require Logger

  @default_limit_mb 10
  @megabyte 1_048_576

  @doc "The configured attachment directory."
  def dir, do: Application.fetch_env!(:custyard, :attachment_dir)

  @doc "Default per-message cap in bytes, used on legacy routes without a channel."
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
      without fetching, for mail the operator has not yet trusted

  Returns `{:ok, rows}`. A fetch failure is recorded as `failed` and never
  raises; the delivery is already stored and must not be retried for this.
  """
  def fetch_for_message(%Message{id: message_id}, descriptors, opts \\ [])
      when is_list(descriptors) do
    limit = Keyword.get(opts, :limit_bytes, default_limit_bytes())
    skip = Keyword.get(opts, :skip)

    {rows, _used} =
      Enum.reduce(descriptors, {[], 0}, fn descriptor, {rows, used} ->
        {attrs, used} = process_descriptor(descriptor, used, limit, skip)
        {[insert!(message_id, descriptor, attrs) | rows], used}
      end)

    {:ok, Enum.reverse(rows)}
  end

  defp process_descriptor(_descriptor, used, _limit, skip) when is_binary(skip),
    do: {skipped(skip), used}

  defp process_descriptor(_descriptor, used, 0, _skip), do: {skipped("disabled"), used}

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
          {store(bytes), used + byte_size(bytes)}

        {:error, :too_large} ->
          {skipped("too_large"), used}

        {:error, reason} ->
          Logger.warning("Attachment fetch failed: #{inspect(reason)}")
          {%{state: :failed, skip_reason: "fetch_failed"}, used}
      end
    end
  end

  defp declared_size(%{size: size}) when is_integer(size) and size > 0, do: size
  defp declared_size(_descriptor), do: 0

  defp skipped(reason), do: %{state: :skipped, skip_reason: reason}

  # Content-addressed write: the temp file lands next to its final name so the
  # rename is atomic on the same filesystem; identical content is kept once.
  defp store(bytes) do
    sha = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    relative = Path.join(binary_part(sha, 0, 2), sha)
    final = Path.join(dir(), relative)

    unless File.exists?(final) do
      File.mkdir_p!(Path.dirname(final))
      tmp = final <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))
      File.write!(tmp, bytes)
      File.rename!(tmp, final)
    end

    %{
      state: :fetched,
      sha256: sha,
      storage_path: relative,
      size: byte_size(bytes),
      sniffed_type: Sniffer.sniff(bytes)
    }
  end

  defp insert!(message_id, descriptor, attrs) do
    base = %{
      message_id: message_id,
      filename: descriptor[:filename],
      content_type: string_or_nil(descriptor[:content_type]),
      content_id: string_or_nil(descriptor[:content_id]),
      size: attrs[:size] || declared_or_nil(descriptor)
    }

    %MessageAttachment{}
    |> MessageAttachment.changeset(Map.merge(base, attrs))
    |> Repo.insert!()
  end

  defp declared_or_nil(%{size: size}) when is_integer(size), do: size
  defp declared_or_nil(_descriptor), do: nil

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil

  @doc "Absolute path of a fetched attachment's file, nil for other states."
  def file_path(%MessageAttachment{state: :fetched, storage_path: path}) when is_binary(path),
    do: Path.join(dir(), path)

  def file_path(%MessageAttachment{}), do: nil

  @doc """
  An attachment the operator may download: fetched, on a message the
  operator's role and organization give access to. `nil` otherwise, so the
  caller answers 404 for missing and foreign attachments alike.
  """
  def get_for_operator(id, operator) when is_integer(id) do
    query =
      from a in MessageAttachment,
        join: m in Message,
        on: m.id == a.message_id,
        join: c in Conversation,
        on: c.id == m.conversation_id,
        where: a.id == ^id and a.state == :fetched and is_nil(m.deleted_at),
        select: {a, c}

    case Repo.one(query) do
      {attachment, conversation} ->
        if Authorization.can_access_conversation?(operator, conversation),
          do: attachment,
          else: nil

      nil ->
        nil
    end
  end

  @doc """
  Delete files in the attachment directory that no row references any more
  (their messages were swept or hard-deleted). Returns the count removed.
  """
  def sweep_orphan_files do
    directory = dir()

    if File.dir?(directory) do
      referenced =
        from(a in MessageAttachment, where: not is_nil(a.sha256), select: a.sha256)
        |> Repo.all()
        |> MapSet.new()

      directory
      |> Path.join("*/*")
      |> Path.wildcard()
      |> Enum.reject(fn path -> MapSet.member?(referenced, Path.basename(path)) end)
      |> Enum.reduce(0, fn path, count ->
        case File.rm(path) do
          :ok -> count + 1
          {:error, _reason} -> count
        end
      end)
    else
      0
    end
  end

  @doc "Human-readable size."
  def format_bytes(nil), do: ""
  def format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  def format_bytes(bytes) when bytes < @megabyte, do: "#{Float.round(bytes / 1024, 1)} KB"
  def format_bytes(bytes), do: "#{Float.round(bytes / @megabyte, 1)} MB"
end
