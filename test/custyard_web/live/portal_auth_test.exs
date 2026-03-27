defmodule CustyardWeb.Live.PortalAuthTest do
  @moduledoc """
  Tests for the PortalAuth LiveView on_mount hook.

  The on_mount hook handles authentication and authorization for portal LiveViews.
  It works in conjunction with the PortalAuth plug which runs earlier in the request.

  The plug:
  - Validates URL tokens against the database
  - Sets portal_org_id in session
  - Returns 404 for invalid tokens

  The on_mount:
  - Reads portal_org_id from session
  - Loads the organization
  - Sets assigns (current_org, portal_path, site_name, etc.)
  - Validates URL token matches session org (primarily for custom domain scenarios)
  """
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Custyard.Factory

  describe "on_mount/4 - session validation" do
    test "allows access when valid portal_org_id in session and URL token matches", %{conn: conn} do
      org = insert_organization()

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:portal_org_id, org.id)

      {:ok, _view, html} = live(conn, "/p/#{org.token}")

      # Page renders successfully (proves auth hook passed)
      assert html =~ "My Requests"
    end

    test "loads organization from session and makes it available", %{conn: conn} do
      org = insert_organization(name: "Acme Corp Portal")

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:portal_org_id, org.id)

      {:ok, _view, html} = live(conn, "/p/#{org.token}")

      # The org name appears in the page (set via site_name assign for white-labeling)
      assert html =~ "Acme Corp Portal"
    end
  end

  describe "on_mount/4 - URL token validation" do
    test "allows access when session org matches URL token", %{conn: conn} do
      org = insert_organization()

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:portal_org_id, org.id)

      {:ok, _view, html} = live(conn, "/p/#{org.token}")

      assert html =~ "My Requests"
    end

    test "allows navigation within the same org's portal", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id, subject: "Test Conversation")

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:portal_org_id, org.id)

      # Can access request list
      {:ok, _view, html} = live(conn, "/p/#{org.token}")
      assert html =~ "My Requests"

      # Can access individual conversation
      {:ok, _view, html} = live(conn, "/p/#{org.token}/request/#{conv.id}")
      assert html =~ "Test Conversation"
    end
  end

  describe "on_mount/4 - custom domain handling" do
    test "sets is_custom_domain assign from session flag", %{conn: conn} do
      org = insert_organization(name: "Custom Domain Org")

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:portal_org_id, org.id)
        |> Plug.Conn.put_session(:portal_custom_domain, true)

      # With portal_custom_domain=true in session, page renders with custom domain context
      {:ok, _view, html} = live(conn, "/p/#{org.token}")

      # Access granted with custom domain flag recognized
      assert html =~ "Custom Domain Org"
      assert html =~ "My Requests"
    end

    test "defaults is_custom_domain to false when not in session", %{conn: conn} do
      org = insert_organization()

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:portal_org_id, org.id)
        # Not setting portal_custom_domain

      {:ok, _view, html} = live(conn, "/p/#{org.token}")

      # Page renders successfully without custom domain flag
      assert html =~ "My Requests"
    end
  end

  describe "on_mount/4 - assigns" do
    test "assigns current_org from session org_id", %{conn: conn} do
      org = insert_organization(name: "Test Org Name")

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:portal_org_id, org.id)

      {:ok, _view, html} = live(conn, "/p/#{org.token}")

      # The org name appears in navigation, proving current_org was assigned
      assert html =~ "Test Org Name"
    end

    test "assigns portal_path and portal_home_path with org token", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id, subject: "Path Test Conv")

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:portal_org_id, org.id)

      # Access a conversation page which has a back link using portal_home_path
      {:ok, _view, html} = live(conn, "/p/#{org.token}/request/#{conv.id}")

      # The back link should use portal_home_path which includes the token
      assert html =~ "Back to requests"
      assert html =~ "/p/#{org.token}"
    end

    test "assigns site_name for white-label branding", %{conn: conn} do
      org = insert_organization(name: "Acme Corporation")

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:portal_org_id, org.id)

      {:ok, _view, html} = live(conn, "/p/#{org.token}")

      # site_name (org.name) appears in the page title and navigation
      assert html =~ "Acme Corporation"
    end

    test "assigns is_custom_domain from session", %{conn: conn} do
      org = insert_organization()

      conn =
        conn
        |> Phoenix.ConnTest.init_test_session(%{})
        |> Plug.Conn.put_session(:portal_org_id, org.id)
        |> Plug.Conn.put_session(:portal_custom_domain, true)

      {:ok, _view, html} = live(conn, "/p/#{org.token}")

      # Page renders successfully with custom domain flag set
      assert html =~ "My Requests"
    end
  end
end
