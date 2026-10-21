defmodule CustyardWeb.Operator.AttachmentController do
  @moduledoc """
  Authenticated download of an inbound email attachment
  (spec-inbound-channels D9).

  The file is served from the attachment directory under the type sniffed
  from its bytes, always as a download, never inline: an attachment is
  hostile content and must not render in the operator's origin. Types
  outside a small allowlist go out as `application/octet-stream`. A missing,
  unfetched or foreign-organization attachment is a 404.
  """

  use CustyardWeb, :controller

  alias Custyard.{Attachments, MessageAttachment}

  @inline_safe_types ~w(image/png image/jpeg image/gif image/webp application/pdf text/plain)

  def show(conn, %{"id" => id}) do
    with {int_id, ""} <- Integer.parse(id),
         %MessageAttachment{} = attachment <-
           Attachments.get_for_operator(int_id, conn.assigns.current_operator),
         path when is_binary(path) <- Attachments.file_path(attachment),
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
      _not_available ->
        conn |> put_status(:not_found) |> text("Not found")
    end
  end

  defp served_type(type) when type in @inline_safe_types, do: type
  defp served_type(_type), do: "application/octet-stream"
end
