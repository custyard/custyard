defmodule CustyardWeb.Portal.AttachmentController do
  @moduledoc """
  Portal download of an inbound email attachment (spec-inbound-channels D9,
  D10). The portal organization comes from `CustyardWeb.Plugs.PortalAuth`,
  by token or custom domain. Only a fetched attachment on a visible message
  of that organization's thread is served: never one on an internal
  note, a deleted message or a suspect thread. Anything else is the
  same 404.
  """

  use CustyardWeb, :controller

  alias Custyard.Attachments
  alias CustyardWeb.AttachmentDownload

  def show(conn, %{"id" => id}) do
    case Integer.parse(id) do
      {int_id, ""} ->
        attachment = Attachments.get_for_portal(int_id, conn.assigns.current_org.id)
        AttachmentDownload.send_attachment(conn, attachment)

      _invalid ->
        AttachmentDownload.not_found(conn)
    end
  end
end
