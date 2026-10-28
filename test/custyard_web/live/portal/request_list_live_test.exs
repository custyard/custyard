defmodule CustyardWeb.Portal.RequestListLiveTest do
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Custyard.Factory

  describe "mount" do
    test "renders request list page", %{conn: conn} do
      org = insert_organization()

      {:ok, _view, html} = live(conn, ~p"/portal/#{portal_token(org)}")

      assert html =~ "My Requests"
      assert html =~ "New Request"
    end

    test "shows empty state when no conversations", %{conn: conn} do
      org = insert_organization()

      {:ok, _view, html} = live(conn, ~p"/portal/#{portal_token(org)}")

      assert html =~ "No open requests"
    end

    test "lists conversations for the organization", %{conn: conn} do
      org = insert_organization()

      conv1 = insert_conversation(organization_id: org.id, subject: "Test Subject One")
      conv2 = insert_conversation(organization_id: org.id, subject: "Test Subject Two")

      {:ok, _view, html} = live(conn, ~p"/portal/#{portal_token(org)}")

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

      {:ok, _view, html} = live(conn, ~p"/portal/#{portal_token(org)}")

      assert html =~ active_conv.subject
      refute html =~ resolved_conv.subject
    end

    test "does not show conversations from other organizations", %{conn: conn} do
      org1 = insert_organization()
      org2 = insert_organization()

      conv1 = insert_conversation(organization_id: org1.id, subject: "Org1 Request")
      conv2 = insert_conversation(organization_id: org2.id, subject: "Org2 Request")

      {:ok, _view, html} = live(conn, ~p"/portal/#{portal_token(org1)}")

      assert html =~ conv1.subject
      refute html =~ conv2.subject
    end
  end

  describe "portal credentials" do
    test "optional contact attribution does not narrow customer access", %{conn: conn} do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, name: "Alice Smith")
      other = insert_contact(organization_id: org.id)

      first =
        insert_conversation(
          organization_id: org.id,
          contact_id: contact.id,
          subject: "Alice thread"
        )

      second =
        insert_conversation(
          organization_id: org.id,
          contact_id: other.id,
          subject: "Other customer thread"
        )

      {:ok, _, token} =
        Custyard.PortalCredentials.issue(
          portal_scope(org),
          org.id,
          contact.id
        )

      {:ok, _, html} = live(conn, ~p"/portal/#{token}")
      assert html =~ "Viewing as"
      assert html =~ "Alice Smith"
      assert html =~ first.subject
      assert html =~ second.subject
      refute html =~ "toggle_admin_mode"
    end

    test "query parameters cannot impersonate contacts", %{conn: conn} do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, name: "Impersonated")
      {:ok, _, html} = live(conn, ~p"/portal/#{portal_token(org)}?as=#{contact.id}&admin=true")
      refute html =~ "Viewing as"
      refute html =~ "Impersonated"
      refute html =~ "toggle_admin_mode"
    end

    test "revocation closes an open portal before handling updates", %{conn: conn} do
      org = insert_organization()

      {:ok, credential, token} =
        Custyard.PortalCredentials.issue(
          portal_scope(org),
          org.id
        )

      {:ok, view, _} = live(conn, ~p"/portal/#{token}")

      {:ok, _} =
        Custyard.PortalCredentials.revoke(
          portal_scope(org),
          credential
        )

      send(view.pid, {:conversation_created, 1})
      assert_redirect(view, "/")
    end
  end

  describe "navigation" do
    test "links to new request page", %{conn: conn} do
      org = insert_organization()

      {:ok, view, _html} = live(conn, ~p"/portal/#{portal_token(org)}")

      assert view |> element("a", "New Request") |> has_element?()
    end

    test "links to individual conversation pages", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id, subject: "Test Subject")

      {:ok, view, _html} = live(conn, ~p"/portal/#{portal_token(org)}")

      assert view |> element("a[href*='/request/#{conv.id}']") |> has_element?()
    end
  end

  describe "real-time updates" do
    test "updates when conversation is created", %{conn: conn} do
      org = insert_organization()

      {:ok, view, html} = live(conn, ~p"/portal/#{portal_token(org)}")
      refute html =~ "New PubSub Request"

      # Create new conversation and broadcast
      conv = insert_conversation(organization_id: org.id, subject: "New PubSub Request")

      Phoenix.PubSub.broadcast(
        Custyard.PubSub,
        "conversations:org:#{org.id}",
        {:conversation_created, conv.id}
      )

      # Wait for update
      Process.sleep(50)

      html = render(view)
      assert html =~ "New PubSub Request"
    end
  end
end
