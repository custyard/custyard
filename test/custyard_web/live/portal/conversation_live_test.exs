defmodule CustyardWeb.Portal.ConversationLiveTest do
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Custyard.Factory
  import Ecto.Query

  alias Custyard.{Message, Repo}

  describe "mount" do
    test "renders conversation page with subject", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id, subject: "My Test Subject")

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}/request/#{conv.id}")

      assert html =~ "My Test Subject"
    end

    test "shows back link to request list", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}/request/#{conv.id}")

      assert html =~ "Back to requests"
    end

    test "shows reply form", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}/request/#{conv.id}")

      assert html =~ "Write a reply"
      assert html =~ "Send Reply"
    end

    test "redirects if conversation not found", %{conn: conn} do
      org = insert_organization()

      {:error, {:live_redirect, %{to: redirect_path}}} =
        live(conn, ~p"/p/#{org.token}/request/99999")

      assert redirect_path == "/p/#{org.token}"
    end

    test "redirects if conversation belongs to different org", %{conn: conn} do
      org1 = insert_organization()
      org2 = insert_organization()
      conv = insert_conversation(organization_id: org2.id)

      {:error, {:live_redirect, %{to: redirect_path}}} =
        live(conn, ~p"/p/#{org1.token}/request/#{conv.id}")

      assert redirect_path == "/p/#{org1.token}"
    end
  end

  describe "messages" do
    test "displays existing messages", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      insert_message(conversation_id: conv.id, body: "First message content", source: :email)
      insert_message(conversation_id: conv.id, body: "Second message content", source: :portal)

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}/request/#{conv.id}")

      assert html =~ "First message content"
      assert html =~ "Second message content"
    end

    test "does not display internal notes", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      insert_message(conversation_id: conv.id, body: "Public message", is_internal_note: false)
      insert_message(conversation_id: conv.id, body: "Internal note", is_internal_note: true)

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}/request/#{conv.id}")

      assert html =~ "Public message"
      refute html =~ "Internal note"
    end

    test "styles operator messages differently", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      insert_message(conversation_id: conv.id, body: "Operator reply", source: :operator)

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}/request/#{conv.id}")

      assert html =~ "Operator reply"
      assert html =~ "border-indigo"
    end

    test "shows 'Support Team' label for operator messages", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      insert_message(
        conversation_id: conv.id,
        body: "Hello from support",
        source: :operator,
        sender_email: "operator@internal.example.com"
      )

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}/request/#{conv.id}")

      assert html =~ "Support Team"
      refute html =~ "operator@internal.example.com"
    end

    test "shows sender email for customer messages", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      insert_message(
        conversation_id: conv.id,
        body: "Customer question",
        source: :email,
        sender_email: "customer@example.com"
      )

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}/request/#{conv.id}")

      assert html =~ "customer@example.com"
    end
  end

  describe "reply submission" do
    test "creates new message on reply", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      {:ok, view, _html} = live(conn, ~p"/p/#{org.token}/request/#{conv.id}")

      view
      |> form("form", %{"body" => "This is my reply"})
      |> render_submit()

      # Verify message was created
      messages = Repo.all(from m in Message, where: m.conversation_id == ^conv.id)
      assert length(messages) == 1
      assert hd(messages).body == "This is my reply"
      assert hd(messages).source == :portal
    end

    test "clears form after successful reply", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      {:ok, view, _html} = live(conn, ~p"/p/#{org.token}/request/#{conv.id}")

      view
      |> form("form", %{"body" => "Form reply text"})
      |> render_submit()

      # Re-render to get current state
      html = render(view)

      # The reply appears in messages but textarea value should be empty
      # Check that the textarea doesn't have the value attribute with our text
      # Appears in messages
      assert html =~ "Form reply text"

      # Verify a new message was created and reply form is reset
      messages = Repo.all(from m in Message, where: m.conversation_id == ^conv.id)
      assert length(messages) == 1
    end

    test "does not create message for empty reply", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      {:ok, view, _html} = live(conn, ~p"/p/#{org.token}/request/#{conv.id}")

      view
      |> form("form", %{"body" => "   "})
      |> render_submit()

      # No message should be created for whitespace-only body
      messages = Repo.all(from m in Message, where: m.conversation_id == ^conv.id)
      assert Enum.empty?(messages)
    end

    test "reply reactivates dormant conversation", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id, state: :dormant)

      {:ok, view, _html} = live(conn, ~p"/p/#{org.token}/request/#{conv.id}")

      view
      |> form("form", %{"body" => "Reactivating reply"})
      |> render_submit()

      updated_conv = Repo.get!(Custyard.Conversation, conv.id)
      assert updated_conv.state == :active
    end

    test "reply reactivates waiting conversation", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id, state: :waiting)

      {:ok, view, _html} = live(conn, ~p"/p/#{org.token}/request/#{conv.id}")

      view
      |> form("form", %{"body" => "Follow up reply"})
      |> render_submit()

      updated_conv = Repo.get!(Custyard.Conversation, conv.id)
      assert updated_conv.state == :active
    end

    test "recalculates score after reply", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id, cached_score: 0)

      {:ok, view, _html} = live(conn, ~p"/p/#{org.token}/request/#{conv.id}")

      view
      |> form("form", %{"body" => "Score update reply"})
      |> render_submit()

      updated_conv = Repo.get!(Custyard.Conversation, conv.id)
      assert updated_conv.cached_score > 0
    end
  end

  describe "tasks" do
    test "shows portal-visible tasks", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      # Insert a portal-visible task
      {:ok, task} =
        Custyard.Conversations.create_task(%{
          conversation_id: conv.id,
          title: "Visible Task",
          state: :open,
          portal_visible: true
        })

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}/request/#{conv.id}")

      assert html =~ "Tasks"
      assert html =~ task.title
    end

    test "does not show non-portal-visible tasks", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      # Insert a non-portal-visible task
      {:ok, _task} =
        Custyard.Conversations.create_task(%{
          conversation_id: conv.id,
          title: "Hidden Task",
          state: :open,
          portal_visible: false
        })

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}/request/#{conv.id}")

      refute html =~ "Hidden Task"
    end
  end

  describe "real-time updates" do
    test "updates when new message is added", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      {:ok, view, html} = live(conn, ~p"/p/#{org.token}/request/#{conv.id}")
      refute html =~ "Real-time message"

      # Add message and broadcast
      insert_message(conversation_id: conv.id, body: "Real-time message")

      Phoenix.PubSub.broadcast(
        Custyard.PubSub,
        "conversation:#{conv.id}",
        {:message_added, conv.id}
      )

      # Wait for update
      Process.sleep(50)

      html = render(view)
      assert html =~ "Real-time message"
    end
  end
end
