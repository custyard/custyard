defmodule CustyardWeb.Operator.AttachmentController do
  @moduledoc """
  Authenticated download of an inbound email attachment
  (spec-inbound-channels D9). A missing, unfetched or foreign-organization
  attachment is a 404; `CustyardWeb.AttachmentDownload` sends the file.
  """

  use CustyardWeb, :controller

  alias Custyard.Attachments
  alias CustyardWeb.AttachmentDownload

  def show(conn, %{"id" => id}) do
    case Integer.parse(id) do
      {int_id, ""} ->
        attachment = Attachments.get_for_operator(int_id, conn.assigns.current_operator)
        AttachmentDownload.send_attachment(conn, attachment)

      _invalid ->
        AttachmentDownload.not_found(conn)
    end
  end
end
