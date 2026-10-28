defmodule CustyardWeb.Operator.AttachmentController do
  @moduledoc """
  Authenticated download of an inbound email attachment
  (spec-inbound-channels D9). A missing, unfetched or foreign-organization
  attachment is a 404; `CustyardWeb.AttachmentDownload` sends the file.
  `inline/2` serves a raster image for an email's `cid:` reference.
  """

  use CustyardWeb, :controller

  alias Custyard.Attachments
  alias CustyardWeb.AttachmentDownload

  def show(conn, %{"id" => id}) do
    case Integer.parse(id) do
      {int_id, ""} ->
        attachment = Attachments.get(conn.assigns.current_scope, int_id)
        AttachmentDownload.send_attachment(conn, attachment)

      _invalid ->
        AttachmentDownload.not_found(conn)
    end
  end

  def inline(conn, %{"id" => id}) do
    case Integer.parse(id) do
      {int_id, ""} ->
        attachment = Attachments.get(conn.assigns.current_scope, int_id)
        AttachmentDownload.send_inline_image(conn, attachment)

      _invalid ->
        AttachmentDownload.not_found(conn)
    end
  end
end
