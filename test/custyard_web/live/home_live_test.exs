defmodule CustyardWeb.HomeLiveTest do
  use CustyardWeb.ConnCase
  import Phoenix.LiveViewTest

  test "public landing page identifies the workspace and links to staff sign in", %{conn: conn} do
    {:ok, _, html} = live(conn, "/")
    assert html =~ "Welcome to Tenant"
    assert html =~ "Staff sign in"
    assert html =~ "href=\"/app/login\""
  end
end
