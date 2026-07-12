defmodule CustyardWeb.Prospect.ConversationController do
  @moduledoc """
  The uniform "conversation unavailable" page.

  Invalid, revoked, purged, and malformed access tokens all land here — one
  identical rendering for every failure class, so token handling exposes no
  validity oracle. A dead view: unauthenticated failures never cost a
  LiveView socket.
  """

  use CustyardWeb, :controller

  alias Custyard.Settings

  plug :put_layout, html: {CustyardWeb.Layouts, :intake}

  def unavailable(conn, _params) do
    conn
    |> assign(:branding, Settings.get_branding())
    |> assign(:page_title, "Conversation unavailable")
    |> render(:unavailable)
  end
end
