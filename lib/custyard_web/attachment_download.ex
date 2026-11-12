defmodule CustyardWeb.AttachmentDownload do
  @moduledoc """
  Sends a stored inbound email attachment (spec-inbound-channels D9) for the
  staff and portal download controllers, which each decide who may fetch
  which attachment.

  The content is served under the type sniffed from its bytes, always as a
  download, never inline: an attachment is hostile content and must not
  render in the application's origin. Types outside a small allowlist go out
  as `application/octet-stream`. A row whose content is missing is a 404.

  The content comes out of the database (`Custyard.Files`) about a megabyte
  at a time and goes to the client as a chunked response, so a large
  attachment is never whole in memory. The response therefore carries no
  `content-length`.
  """

  import Phoenix.Controller, only: [text: 2]
  import Plug.Conn

  alias Custyard.{Attachments, Files, MessageAttachment}
  alias Custyard.Files.StoredFile

  @inline_safe_types ~w(image/png image/jpeg image/gif image/webp application/pdf text/plain)
  # Types an email may show inline (`cid:` images): raster only, never SVG.
  @inline_image_types ~w(image/png image/jpeg image/gif image/webp)

  @doc "Send `attachment` as a download, or 404 when it is nil or its content is gone."
  def send_attachment(conn, %MessageAttachment{} = attachment) do
    if Attachments.downloadable?(attachment) do
      send_stored(
        conn,
        attachment,
        served_type(attachment.sniffed_type),
        content_disposition("attachment", attachment.filename || "attachment")
      )
    else
      not_found(conn)
    end
  end

  def send_attachment(conn, nil), do: not_found(conn)

  @doc """
  Whether `attachment` may be shown inline as an email's `cid:` image: a
  fetched file whose bytes sniffed as a raster image.
  """
  def inline_image?(%MessageAttachment{state: :fetched, scan_status: :clean, sniffed_type: type}),
    do: type in @inline_image_types

  def inline_image?(_attachment), do: false

  @doc """
  Send a raster image inline, for an email's `cid:` reference; anything that
  is not `inline_image?/1` is a 404. The sniffed type, `nosniff` and the
  sandbox CSP still apply.
  """
  def send_inline_image(conn, %MessageAttachment{} = attachment) do
    if inline_image?(attachment) do
      send_stored(
        conn,
        attachment,
        attachment.sniffed_type,
        content_disposition("inline", attachment.filename || "image")
      )
    else
      not_found(conn)
    end
  end

  def send_inline_image(conn, nil), do: not_found(conn)

  @doc "The uniform 404 for an attachment that is missing or not the caller's."
  def not_found(conn), do: conn |> put_status(:not_found) |> text("Not found")

  # Sobelow flags the content type as user-controlled; it is not. Both callers
  # pass one of the literals in @inline_safe_types or @inline_image_types, or
  # the octet-stream fallback (served_type/1); the type an email declared is
  # never used. Nothing here takes a path either: the content is the tenant's
  # stored file for the row's own SHA-256 (Custyard.Attachments.stored_file/1),
  # looked up in the database, never by request input or the declared filename.
  # sobelow_skip ["XSS.ContentType"]
  defp send_stored(conn, attachment, type, disposition) do
    # The first part is read before the status goes out, so content that is
    # missing is still the uniform 404 and never a 200 with nothing behind it.
    with %StoredFile{} = file <- Attachments.stored_file(attachment),
         {:ok, parts} <- first_part(file) do
      conn
      |> put_resp_content_type(type, nil)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
      |> put_resp_header("cache-control", "private, no-store")
      |> put_resp_header("content-disposition", disposition)
      |> send_chunked(200)
      |> send_parts(parts)
    else
      _not_available -> not_found(conn)
    end
  end

  # Files.stream/1 runs one query per element. Stepping through it by hand
  # keeps the first part for the response instead of fetching it twice.
  defp first_part(file) do
    {:suspended, nil, next} =
      Enumerable.reduce(Files.stream(file), {:suspend, nil}, fn part, _acc ->
        {:suspend, part}
      end)

    {:ok, next_part(next)}
  rescue
    Files.CorruptError -> :error
  end

  defp next_part(next) do
    case next.({:cont, nil}) do
      {:suspended, part, next} -> {part, next}
      {_finished, _acc} -> :done
    end
  end

  defp send_parts(conn, :done), do: conn

  # Past the first part the status is already sent. A chunk missing from here
  # on raises Files.CorruptError out of the request, so the server abandons
  # the response unfinished and the client sees a failed download, not a
  # short file that looks complete.
  defp send_parts(conn, {part, next}) do
    case chunk(conn, part) do
      {:ok, conn} ->
        send_parts(conn, next_part(next))

      # The client went away. There is nobody to tell and nothing to undo.
      {:error, _reason} ->
        next.({:halt, nil})
        conn
    end
  end

  # The header Phoenix.Controller.send_download/3 writes, which sent these
  # files before: the name percent-encoded, and repeated in the `filename*`
  # form when encoding changed it.
  defp content_disposition(type, filename) do
    encoded = URI.encode(filename, &URI.char_unreserved?/1)
    disposition = ~s(#{type}; filename="#{encoded}")

    if encoded == filename,
      do: disposition,
      else: disposition <> "; filename*=utf-8''#{encoded}"
  end

  defp served_type(type) when type in @inline_safe_types, do: type
  defp served_type(_type), do: "application/octet-stream"
end
