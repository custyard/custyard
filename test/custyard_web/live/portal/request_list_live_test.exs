defmodule CustyardWeb.Portal.RequestListLiveTest do
  @moduledoc """
  Tests for the portal request list LiveView.

  NOTE: Contact impersonation tests (?as= param) rely on the
  :allow_contact_impersonation config being set to true in test.exs.
  In production builds, this config defaults to false and the
  impersonation code path is compiled out entirely.
  """
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Custyard.Factory

  describe "mount" do
    test "renders request list page", %{conn: conn} do
      org = insert_organization()

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}")

      assert html =~ "My Requests"
      assert html =~ "New Request"
    end

    test "shows empty state when no conversations", %{conn: conn} do
      org = insert_organization()

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}")

      assert html =~ "No open requests"
    end

    test "lists conversations for the organization", %{conn: conn} do
      org = insert_organization()

      conv1 = insert_conversation(organization_id: org.id, subject: "Test Subject One")
      conv2 = insert_conversation(organization_id: org.id, subject: "Test Subject Two")

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}")

      assert html =~ conv1.subject
      assert html =~ conv2.subject
    end

    test "does not show resolved conversations", %{conn: conn} do
      org = insert_organization()

      active_conv =
        insert_conversation(organization_id: org.id, state: :active, subject: "Active Request")

      resolved_conv =
        insert_conversation(
          organization_id: org.id,
          state: :resolved,
          subject: "Resolved Request"
        )

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}")

      assert html =~ active_conv.subject
      refute html =~ resolved_conv.subject
    end

    test "does not show conversations from other organizations", %{conn: conn} do
      org1 = insert_organization()
      org2 = insert_organization()

      conv1 = insert_conversation(organization_id: org1.id, subject: "Org1 Request")
      conv2 = insert_conversation(organization_id: org2.id, subject: "Org2 Request")

      {:ok, _view, html} = live(conn, ~p"/p/#{org1.token}")

      assert html =~ conv1.subject
      refute html =~ conv2.subject
    end
  end

  describe "contact impersonation config" do
    # Contact impersonation via ?as= param is gated by compile-time config.
    # These tests verify the config is properly set in test environment.
    # In production, :allow_contact_impersonation defaults to false and
    # the impersonation code is compiled out.

    test "impersonation is enabled in test environment" do
      # This should be true in test.exs config
      assert Application.get_env(:custyard, :allow_contact_impersonation, false) == true
    end
  end

  describe "contact filtering" do
    # NOTE: These tests require :allow_contact_impersonation to be true in config.
    # In production builds, the ?as= param is ignored.

    test "shows all conversations when no contact specified", %{conn: conn} do
      org = insert_organization()

      contact1 = insert_contact(organization_id: org.id)
      contact2 = insert_contact(organization_id: org.id)

      conv1 =
        insert_conversation(
          organization_id: org.id,
          contact_id: contact1.id,
          subject: "Contact1 Request"
        )

      conv2 =
        insert_conversation(
          organization_id: org.id,
          contact_id: contact2.id,
          subject: "Contact2 Request"
        )

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}")

      assert html =~ conv1.subject
      assert html =~ conv2.subject
    end

    test "filters to contact's conversations when as param provided", %{conn: conn} do
      org = insert_organization()

      contact1 = insert_contact(organization_id: org.id)
      contact2 = insert_contact(organization_id: org.id)

      conv1 =
        insert_conversation(
          organization_id: org.id,
          contact_id: contact1.id,
          subject: "Contact1 Request"
        )

      conv2 =
        insert_conversation(
          organization_id: org.id,
          contact_id: contact2.id,
          subject: "Contact2 Request"
        )

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}?as=#{contact1.id}")

      assert html =~ conv1.subject
      refute html =~ conv2.subject
    end

    test "shows viewing as message for authenticated contact", %{conn: conn} do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, name: "Alice Smith")

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}?as=#{contact.id}")

      assert html =~ "Viewing as"
      assert html =~ "Alice Smith"
    end
  end

  describe "admin mode" do
    test "admin toggle is not shown for non-admin contacts", %{conn: conn} do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, is_admin: false)

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}?as=#{contact.id}")

      refute html =~ "Admin view"
      refute html =~ "toggle_admin_mode"
    end

    test "admin toggle is shown for admin contacts", %{conn: conn} do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, is_admin: true)

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}?as=#{contact.id}")

      assert html =~ "Admin view"
    end

    test "toggle_admin_mode event switches between modes", %{conn: conn} do
      org = insert_organization()
      admin_contact = insert_contact(organization_id: org.id, is_admin: true)
      other_contact = insert_contact(organization_id: org.id)

      conv1 =
        insert_conversation(
          organization_id: org.id,
          contact_id: admin_contact.id,
          subject: "Admin Request"
        )

      conv2 =
        insert_conversation(
          organization_id: org.id,
          contact_id: other_contact.id,
          subject: "Other Request"
        )

      {:ok, view, html} = live(conn, ~p"/p/#{org.token}?as=#{admin_contact.id}")

      # Initially shows only admin's conversations
      assert html =~ conv1.subject
      refute html =~ conv2.subject
      assert html =~ "My Requests"

      # Toggle to admin mode
      html = view |> element("button[phx-click=toggle_admin_mode]") |> render_click()

      # Now shows all org conversations
      assert html =~ conv1.subject
      assert html =~ conv2.subject
      assert html =~ "All Organization Requests"
    end

    test "toggle_admin_mode event is rejected for non-admin contacts", %{conn: conn} do
      org = insert_organization()
      non_admin = insert_contact(organization_id: org.id, is_admin: false)
      other_contact = insert_contact(organization_id: org.id)

      _conv1 =
        insert_conversation(
          organization_id: org.id,
          contact_id: non_admin.id,
          subject: "My Request"
        )

      conv2 =
        insert_conversation(
          organization_id: org.id,
          contact_id: other_contact.id,
          subject: "Other Request"
        )

      {:ok, view, html} = live(conn, ~p"/p/#{org.token}?as=#{non_admin.id}")

      # Initially shows only non-admin's conversations
      assert html =~ "My Request"
      refute html =~ conv2.subject
      assert html =~ "My Requests"

      # Directly push toggle_admin_mode event (simulating JS manipulation)
      html = render_click(view, "toggle_admin_mode", %{})

      # admin_mode should remain false - still showing only user's conversations
      assert html =~ "My Request"
      refute html =~ conv2.subject
      assert html =~ "My Requests"
      refute html =~ "All Organization Requests"
    end
  end

  describe "navigation" do
    test "links to new request page", %{conn: conn} do
      org = insert_organization()

      {:ok, view, _html} = live(conn, ~p"/p/#{org.token}")

      assert view |> element("a", "New Request") |> has_element?()
    end

    test "links to individual conversation pages", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id, subject: "Test Subject")

      {:ok, view, _html} = live(conn, ~p"/p/#{org.token}")

      assert view |> element("a[href*='/request/#{conv.id}']") |> has_element?()
    end
  end

  describe "real-time updates" do
    test "updates when conversation is created", %{conn: conn} do
      org = insert_organization()

      {:ok, view, html} = live(conn, ~p"/p/#{org.token}")
      refute html =~ "New PubSub Request"

      # Create new conversation and broadcast
      conv = insert_conversation(organization_id: org.id, subject: "New PubSub Request")
      Phoenix.PubSub.broadcast(Custyard.PubSub, "conversations", {:conversation_created, conv.id})

      # Wait for update
      Process.sleep(50)

      html = render(view)
      assert html =~ "New PubSub Request"
    end
  end
end
