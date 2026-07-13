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
      contact = insert_contact(organization_id: org.id, email: "pending@customer.com")
      conv = insert_conversation(organization_id: org.id, contact_id: contact.id)

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

  describe "delete message" do
    test "operator soft-deletes a message and the tombstone replaces the body", %{
      conn: conn,
      operator: operator
    } do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      message = insert_message(conversation_id: conv.id, body: "Sensitive customer detail")

      {:ok, view, html} = live(conn, ~p"/operator/conversation/#{conv.id}")
      assert html =~ "Sensitive customer detail"

      html =
        view
        |> element(~s([data-testid="operator-message-delete-#{message.id}"]))
        |> render_click()

      assert html =~ "operator-message-tombstone"
      assert html =~ "This message was deleted"
      refute html =~ "Sensitive customer detail"

      # Soft delete only: the row keeps its body, stamped with the deleter.
      reloaded = Repo.get!(Custyard.Message, message.id)
      assert reloaded.body == "Sensitive customer detail"
      assert %DateTime{} = reloaded.deleted_at
      assert reloaded.deleted_by_operator_id == operator.id
    end

    test "delete affordance requires confirmation and disappears once deleted", %{
      conn: conn,
      operator: operator
    } do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      message = insert_message(conversation_id: conv.id, body: "Doomed message")

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      assert view
             |> element(~s([data-testid="operator-message-delete-#{message.id}"]))
             |> render() =~ "data-confirm"

      {:ok, _} = Conversations.soft_delete_message(message, operator)

      # The message_updated broadcast refreshes the open view: tombstone in,
      # delete affordance gone.
      html = render(view)
      assert html =~ "This message was deleted"
      refute html =~ "Doomed message"
      refute has_element?(view, ~s([data-testid="operator-message-delete-#{message.id}"]))
    end

    test "deleting an unknown message id flashes an error and deletes nothing", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      other_conv = insert_conversation(organization_id: org.id)
      foreign = insert_message(conversation_id: other_conv.id, body: "Other thread")

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      # An id from another conversation is out of scope for this view.
      html = render_click(view, "delete_message", %{"id" => to_string(foreign.id)})

      assert html =~ "Message not found"
      assert Repo.get!(Custyard.Message, foreign.id).deleted_at == nil
    end
  end

  describe "consent-withheld replies (public intake)" do
    test "delivery indicator shows withheld", %{conn: conn} do
      conv = insert_conversation(source: :public_intake)

      insert_prospect(
        conversation_id: conv.id,
        email: "prospect@example.com",
        notify_on_reply: false
      )

      insert_message(
        conversation_id: conv.id,
        source: :operator,
        sender_email: nil,
        body: "Recorded but not emailed",
        delivery_status: :withheld
      )

      {:ok, _view, html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      assert html =~ "delivery-status-withheld"
      assert html =~ "Not emailed"
    end

    test "reply without prospect consent shows the advisory and records withheld", %{conn: conn} do
      conv = insert_conversation(source: :public_intake)

      insert_prospect(
        conversation_id: conv.id,
        email: "prospect@example.com",
        notify_on_reply: false
      )

      {:ok, view, html} = live(conn, ~p"/operator/conversation/#{conv.id}")
      assert html =~ "operator-reply-consent-advisory"

      html =
        view
        |> form("form[phx-submit=send_reply]", body: "Reply without consent")
        |> render_submit()

      [message] = Conversations.list_public_messages(conv.id)
      assert message.delivery_status == :withheld
      assert html =~ "delivery-status-withheld"
      refute html =~ "delivery-status-pending"
    end

    test "advisory is absent when the prospect has opted in", %{conn: conn} do
      conv = insert_conversation(source: :public_intake)

      insert_prospect(
        conversation_id: conv.id,
        email: "prospect@example.com",
        notify_on_reply: true
      )

      {:ok, _view, html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      refute html =~ "operator-reply-consent-advisory"
    end

    test "advisory is absent when no email was captured", %{conn: conn} do
      conv = insert_conversation(source: :public_intake)

      # Prospect row without a captured email: there is no opt-in to speak
      # of, so the opt-in advisory would misstate the cause — the "no reply
      # channel" state is conveyed by the reply-channel badge instead.
      insert_prospect(conversation_id: conv.id)

      {:ok, _view, html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      refute html =~ "operator-reply-consent-advisory"
    end

    test "advisory is absent on non-intake conversations", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      {:ok, _view, html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      refute html =~ "operator-reply-consent-advisory"
    end
  end

  describe "prospect message via label" do
    test "shows the masked prospect email when one was captured", %{conn: conn} do
      conv = insert_conversation(source: :public_intake)
      insert_prospect(conversation_id: conv.id, email: "prospect@example.com")

      # sender_email is nil on real prospect messages (see Intake) — the via
      # label is the only place the captured email should surface.
      insert_message(conversation_id: conv.id, source: :prospect, sender_email: nil, body: "Hi")

      {:ok, _view, html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      assert html =~ "via prospect pro***@example.com"
      refute html =~ "prospect@example.com"
    end

    test "masks all but the first char when the local part is 3 chars or fewer", %{conn: conn} do
      conv = insert_conversation(source: :public_intake)
      insert_prospect(conversation_id: conv.id, email: "abc@example.com")
      insert_message(conversation_id: conv.id, source: :prospect, sender_email: nil, body: "Hi")

      {:ok, _view, html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      assert html =~ "via prospect a***@example.com"
      refute html =~ "abc@example.com"
    end

    test "keeps plain via prospect when no email was captured", %{conn: conn} do
      conv = insert_conversation(source: :public_intake)
      insert_prospect(conversation_id: conv.id)
      insert_message(conversation_id: conv.id, source: :prospect, sender_email: nil, body: "Hi")

      {:ok, _view, html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      assert html =~ "via prospect"
      refute html =~ "via prospect ***"
      refute html =~ "***@"
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

    test "waiting button toggles: clicking on a waiting conversation reverts to active", %{
      conn: conn
    } do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id, state: :waiting)

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      # The button reflects the current state and offers the reverse transition
      assert has_element?(
               view,
               "[data-testid=operator-state-waiting][phx-value-state=active][aria-pressed=true]"
             )

      view
      |> element("[data-testid=operator-state-waiting]")
      |> render_click()

      updated = Conversations.get_conversation!(conv.id)
      assert updated.state == :active
    end

    test "waiting button reflects the toggled state after clicking", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id, state: :active)

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      assert has_element?(
               view,
               "[data-testid=operator-state-waiting][phx-value-state=waiting][aria-pressed=false]"
             )

      view
      |> element("[data-testid=operator-state-waiting]")
      |> render_click()

      assert has_element?(
               view,
               "[data-testid=operator-state-waiting][phx-value-state=active][aria-pressed=true]"
             )

      assert render(view) =~ "click to resume"
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

  describe "nil-organization conversations" do
    defp insert_scoped_operator(org_id, role \\ "agent") do
      {:ok, operator} =
        %OperatorAccount{}
        |> OperatorAccount.changeset(%{
          email: "#{role}-#{System.unique_integer([:positive])}@example.com",
          password: "password123",
          role: role,
          organization_id: org_id
        })
        |> Repo.insert()

      operator
    end

    defp conn_for_operator(operator) do
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:operator_id, operator.id)
    end

    test "renders a nil-org conversation without crashing", %{conn: conn} do
      conv =
        insert_conversation(
          organization_id: nil,
          source: :disambiguation,
          subject: "Anonymous request"
        )

      insert_message(conversation_id: conv.id, body: "Hello from an unlinked prospect")

      {:ok, _view, html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      assert html =~ "Anonymous request"
      assert html =~ "Hello from an unlinked prospect"
      assert html =~ "Unlinked prospect"
      # No org link, no tier badge without an organization
      refute html =~ "operator-sidebar-org-link"
      refute html =~ "operator-tier-badge"
    end

    test "header shows the source badge", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id, source: :portal)

      {:ok, _view, html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      assert html =~ ~s(data-testid="source-badge-portal")
      assert html =~ "Portal"
    end

    test "org-scoped operator can open a nil-org conversation" do
      org = insert_organization()
      operator = insert_scoped_operator(org.id)

      conv =
        insert_conversation(
          organization_id: nil,
          source: :disambiguation,
          subject: "Unlinked but visible"
        )

      conn = conn_for_operator(operator)

      {:ok, _view, html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      assert html =~ "Unlinked but visible"
      assert html =~ "Unlinked prospect"
    end

    test "org-scoped operator still cannot open another org's conversation" do
      org = insert_organization()
      other_org = insert_organization()
      operator = insert_scoped_operator(org.id)

      conv = insert_conversation(organization_id: other_org.id, subject: "Foreign conversation")

      conn = conn_for_operator(operator)

      assert {:error, {:redirect, %{to: "/operator", flash: flash}}} =
               live(conn, ~p"/operator/conversation/#{conv.id}")

      assert flash["error"] =~ "do not have access"
    end

    test "super_admin can open a nil-org conversation", %{conn: conn} do
      # Default setup operator is super_admin
      conv = insert_conversation(organization_id: nil, source: :disambiguation)

      {:ok, _view, html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      assert html =~ conv.subject
    end

    test "reply on a nil-org conversation records the message without crashing", %{conn: conn} do
      conv = insert_conversation(organization_id: nil, source: :disambiguation)

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      view
      |> form("form[phx-submit=send_reply]", body: "Reply to unlinked prospect")
      |> render_submit()

      [message] = Conversations.list_public_messages(conv.id)
      assert message.body == "Reply to unlinked prospect"
      assert message.source == :operator
    end
  end

  describe "convert prospect" do
    test "super_admin converts an unlinked public-intake prospect into a new organization", %{
      conn: conn
    } do
      conv = insert_conversation(organization_id: nil, source: :public_intake)

      insert_prospect(
        conversation_id: conv.id,
        email: "buyer@acme.com",
        email_captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

      {:ok, view, html} = live(conn, ~p"/operator/conversation/#{conv.id}")
      assert html =~ "operator-convert-prospect-btn"

      html =
        view
        |> element("[data-testid=operator-convert-prospect-btn]")
        |> render_click()

      # Prefilled from the prospect's captured email domain.
      assert html =~ ~s(value="acme.com")

      view
      |> form("[data-testid=operator-convert-form]", name: "Acme Corp", domain: "acme.com")
      |> render_submit()

      converted = Conversations.get_conversation!(conv.id) |> Repo.preload(:organization)
      assert converted.organization.name == "Acme Corp"
      assert converted.source == :public_intake
    end

    test "the convert button is hidden for a conversation already linked to an organization", %{
      conn: conn
    } do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id, source: :public_intake)

      {:ok, _view, html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      refute html =~ "operator-convert-prospect-btn"
    end

    test "admin operators do not see the convert button on a nil-org prospect" do
      org = insert_organization()
      operator = insert_scoped_operator(org.id, "admin")
      conv = insert_conversation(organization_id: nil, source: :public_intake)

      conn = conn_for_operator(operator)
      {:ok, _view, html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      refute html =~ "operator-convert-prospect-btn"
    end

    test "a direct convert_prospect event from a non-super-admin is refused" do
      org = insert_organization()
      operator = insert_scoped_operator(org.id, "admin")
      conv = insert_conversation(organization_id: nil, source: :public_intake)

      conn = conn_for_operator(operator)
      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      html = render_click(view, "convert_prospect", %{"name" => "Sneaky Corp"})

      assert html =~ "Only super admins can convert prospects"
      assert Conversations.get_conversation!(conv.id).organization_id == nil
    end
  end
end
