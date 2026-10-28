defmodule CustyardWeb.Prospect.ThreadController do
  @moduledoc """
  The uniform "thread unavailable" page.

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
    |> assign(:branding, Settings.get_branding(conn.assigns.host_tenant.id))
    |> assign(:page_title, "Thread unavailable")
    |> render(:unavailable)
  end
end
