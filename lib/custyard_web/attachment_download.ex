defmodule CustyardWeb.AttachmentDownload do
  @moduledoc """
  Sends a stored inbound email attachment (spec-inbound-channels D9) for the
  operator and portal download controllers, which each decide who may fetch
  which attachment.

  The file is served under the type sniffed from its bytes, always as a
  download, never inline: an attachment is hostile content and must not
  render in the application's origin. Types outside a small allowlist go out
  as `application/octet-stream`. A row whose file is missing is a 404.
  """

  import Phoenix.Controller, only: [send_download: 3, text: 2]
  import Plug.Conn

  alias Custyard.{Attachments, MessageAttachment}

  @inline_safe_types ~w(image/png image/jpeg image/gif image/webp application/pdf text/plain)

  @doc "Send `attachment` as a download, or 404 when it is nil or its file is gone."
  # Sobelow flags the two variables below as user-controlled; neither is. The
  # content type is one of the literals in @inline_safe_types or the
  # octet-stream fallback (served_type/1), and the path is built by
  # Custyard.Attachments.file_path/1 from the row's content hash, never from
  # request input or the declared filename.
  # sobelow_skip ["XSS.ContentType", "Traversal.SendDownload"]
  def send_attachment(conn, %MessageAttachment{} = attachment) do
    with path when is_binary(path) <- Attachments.file_path(attachment),
         true <- File.regular?(path) do
      conn
      |> put_resp_content_type(served_type(attachment.sniffed_type), nil)
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", "default-src 'none'; sandbox")
      |> put_resp_header("cache-control", "private, no-store")
      |> send_download({:file, path},
        filename: attachment.filename || "attachment",
        disposition: :attachment,
        content_type: served_type(attachment.sniffed_type)
      )
    else
      _not_available -> not_found(conn)
    end
  end

  def send_attachment(conn, nil), do: not_found(conn)

  @doc "The uniform 404 for an attachment that is missing or not the caller's."
  def not_found(conn), do: conn |> put_status(:not_found) |> text("Not found")

  defp served_type(type) when type in @inline_safe_types, do: type
  defp served_type(_type), do: "application/octet-stream"
end
