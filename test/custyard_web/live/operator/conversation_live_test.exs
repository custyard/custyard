defmodule CustyardWeb.Operator.ConversationLiveTest do
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Custyard.Factory

  alias Custyard.Email.Outbound
  alias Custyard.{Conversations, OperatorAccount, Repo, Scoring}

  setup %{conn: conn} do
    # Create and authenticate an operator
    {:ok, operator} =
      %OperatorAccount{}
      |> OperatorAccount.changeset(%{email: "test@example.com", password: "password123"})
      |> Repo.insert()

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:operator_id, operator.id)

    {:ok, conn: conn, operator: operator}
  end

  describe "mount/3" do
    test "renders conversation view", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      insert_message(conversation_id: conv.id, body: "Hello from customer")

      {:ok, _view, html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      assert html =~ conv.subject
      assert html =~ "Hello from customer"
    end

    test "transitions new conversation to active on view", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id, state: :new)

      {:ok, _view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      updated = Conversations.get_conversation!(conv.id)
      assert updated.state == :active
    end

    test "shows score breakdown", %{conn: conn} do
      org = insert_organization(tier: :enterprise)
      conv = insert_conversation(organization_id: org.id, state: :new, urgency: :urgent)
      Scoring.calculate_and_cache(conv.id)

      {:ok, _view, html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      assert html =~ "Score breakdown"
      assert html =~ "tier"
      assert html =~ "urgency"
    end

    test "shows organization and contact info", %{conn: conn} do
      org = insert_organization(name: "Acme Corp", tier: :enterprise)
      contact = insert_contact(organization_id: org.id, name: "Alice", email: "alice@acme.com")
      conv = insert_conversation(organization_id: org.id, contact_id: contact.id)

      {:ok, _view, html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      assert html =~ "Acme Corp"
      assert html =~ "Alice"
      assert html =~ "alice@acme.com"
    end
  end

  describe "handle_event send_reply" do
    test "creates a reply message", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      view
      |> form("form[phx-submit=send_reply]", body: "This is my reply")
      |> render_submit()

      messages = Conversations.list_public_messages(conv.id)
      assert length(messages) == 1
      assert hd(messages).body == "This is my reply"
      assert hd(messages).source == :operator
    end

    test "reply message has delivery_status pending", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      view
      |> form("form[phx-submit=send_reply]", body: "Outbound reply")
      |> render_submit()

      [message] = Conversations.list_public_messages(conv.id)
      # async delivery is disabled via test config, so status stays :pending
      assert message.delivery_status == :pending
    end

    test "reply message has a generated RFC 5322 message_id", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      view
      |> form("form[phx-submit=send_reply]", body: "Reply with message ID")
      |> render_submit()

      [message] = Conversations.list_public_messages(conv.id)
      assert message.message_id != nil
      # RFC 5322 Message-ID format: <unique.cN@domain>
      assert message.message_id =~ ~r/^<.+\.c\d+@.+>$/
    end

    test "reply message has in_reply_to from last customer message", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      # Insert a customer message with a known message_id
      insert_message(
        conversation_id: conv.id,
        source: :email,
        message_id: "<customer-msg-123@example.com>",
        body: "Customer question"
      )

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      view
      |> form("form[phx-submit=send_reply]", body: "Reply to thread")
      |> render_submit()

      messages = Conversations.list_public_messages(conv.id)
      reply = Enum.find(messages, &(&1.source == :operator))
      assert reply.in_reply_to == "<customer-msg-123@example.com>"
    end

    test "reply threads to the latest of multiple customer messages", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      insert_message(
        conversation_id: conv.id,
        source: :email,
        message_id: "<older-msg@example.com>",
        body: "First question"
      )

      insert_message(
        conversation_id: conv.id,
        source: :email,
        message_id: "<newer-msg@example.com>",
        body: "Follow-up question"
      )

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      view
      |> form("form[phx-submit=send_reply]", body: "Answering the follow-up")
      |> render_submit()

      messages = Conversations.list_public_messages(conv.id)
      reply = Enum.find(messages, &(&1.source == :operator))
      assert reply.in_reply_to == "<newer-msg@example.com>"
    end

    test "reply message in_reply_to is nil when no prior customer messages", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      view
      |> form("form[phx-submit=send_reply]", body: "First message in thread")
      |> render_submit()

      [message] = Conversations.list_public_messages(conv.id)
      assert message.in_reply_to == nil
    end

    test "clears reply input after sending", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      view
      |> form("form[phx-submit=send_reply]", body: "Reply content")
      |> render_submit()

      html = render(view)
      # Message appears in thread and input is empty (value="")
      assert html =~ "Reply content"
      assert html =~ ~s(value="")
    end

    test "empty body does not create a message", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      view
      |> form("form[phx-submit=send_reply]", body: "")
      |> render_submit()

      messages = Conversations.list_public_messages(conv.id)
      assert messages == []
    end

    test "warns the operator when the contact has no email address", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id, contact_id: nil)

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      html =
        view
        |> form("form[phx-submit=send_reply]", body: "Reply into the void")
        |> render_submit()

      # The reply is still recorded, but the operator sees the warning
      assert html =~ "no email address"
      assert [_message] = Conversations.list_public_messages(conv.id)
    end
  end

  describe "delivery status updates" do
    test "delivery indicator updates live when async delivery resolves", %{conn: conn} do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, email: "live@customer.com")
      conv = insert_conversation(organization_id: org.id, contact_id: contact.id)

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      html =
        view
        |> form("form[phx-submit=send_reply]", body: "Watch me get delivered")
        |> render_submit()

      assert html =~ "delivery-status-pending"

      # Resolve the delivery the async task would normally perform; the
      # message_updated broadcast must refresh the indicator in the view.
      [message] = Conversations.list_public_messages(conv.id)
      {:ok, _} = Outbound.deliver(message)

      html = render(view)
      refute html =~ "delivery-status-pending"
      assert html =~ "delivery-status-sent"
    end

    test "delivery indicator shows failed when delivery fails", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id, contact_id: nil)

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      view
      |> form("form[phx-submit=send_reply]", body: "Undeliverable")
      |> render_submit()

      [message] = Conversations.list_public_messages(conv.id)
      {:error, :no_recipient_email, _} = Outbound.deliver(message)

      html = render(view)
      refute html =~ "delivery-status-pending"
      assert html =~ "delivery-status-failed"
    end
  end

  describe "handle_event add_note" do
    test "creates an internal note", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      view
      |> form("form[phx-submit=add_note]", body: "Internal note content")
      |> render_submit()

      # Note should appear in view
      html = render(view)
      assert html =~ "Internal note content"
      assert html =~ "internal note"
    end
  end

  describe "handle_event set_state" do
    test "sets conversation to waiting", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id, state: :active)

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      view
      |> element("[phx-click=set_state][phx-value-state=waiting]")
      |> render_click()

      updated = Conversations.get_conversation!(conv.id)
      assert updated.state == :waiting
    end

    test "sets conversation to resolved", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id, state: :active)

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      view
      |> element("[phx-click=set_state][phx-value-state=resolved]")
      |> render_click()

      updated = Conversations.get_conversation!(conv.id)
      assert updated.state == :resolved
    end
  end

  describe "task CRUD" do
    test "creates a task", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      # Show task form
      view
      |> element("[phx-click=toggle_task_form]")
      |> render_click()

      # Submit task
      view
      |> form("form[phx-submit=add_task]", title: "Fix the bug")
      |> render_submit()

      html = render(view)
      assert html =~ "Fix the bug"
    end

    test "toggles task state", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      {:ok, task} = Conversations.create_task(%{title: "Test task", conversation_id: conv.id})

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      # Toggle task (open -> in_progress)
      view
      |> element("[phx-click=toggle_task][phx-value-id=\"#{task.id}\"]")
      |> render_click()

      updated = Conversations.get_task!(task.id)
      assert updated.state == :in_progress
    end

    test "edits a task", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      {:ok, task} =
        Conversations.create_task(%{title: "Original title", conversation_id: conv.id})

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      # Click edit button
      view
      |> element("[phx-click=edit_task][phx-value-id=\"#{task.id}\"]")
      |> render_click()

      # Submit edit form
      view
      |> form("form[phx-submit=save_task]", title: "Updated title")
      |> render_submit()

      updated = Conversations.get_task!(task.id)
      assert updated.title == "Updated title"
    end

    test "deletes a task", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      {:ok, task} =
        Conversations.create_task(%{title: "Task to delete", conversation_id: conv.id})

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      # Delete task
      view
      |> element("[phx-click=delete_task][phx-value-id=\"#{task.id}\"]")
      |> render_click()

      assert_raise Ecto.NoResultsError, fn -> Conversations.get_task!(task.id) end
    end
  end

  describe "PubSub subscription" do
    test "updates when message_added event received", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      # Simulate a new message being added
      Conversations.create_message!(%{
        conversation_id: conv.id,
        source: :email,
        body: "New incoming message",
        is_internal_note: false
      })

      Phoenix.PubSub.broadcast(
        Custyard.PubSub,
        "conversation:#{conv.id}",
        {:message_added, conv.id}
      )

      :timer.sleep(100)

      html = render(view)
      assert html =~ "New incoming message"
    end
  end
end
