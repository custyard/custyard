defmodule CustyardWeb.Operator.ConversationLiveTest do
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Custyard.Factory

  alias Custyard.Attachments.StubClient
  alias Custyard.Email.Outbound
  alias Custyard.{Attachments, Conversations, OperatorAccount, Repo, Scoring}

  setup %{conn: conn} do
    # Create and authenticate an operator
    {:ok, operator} =
      %OperatorAccount{}
      |> OperatorAccount.changeset(%{email: "test@example.com", password: "password123"})
      |> Repo.insert()

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> put_operator_session(operator.id)

    {:ok, conn: conn, operator: operator}
  end

  test "clearing suspect starts recovery and retains an explicit retry when unavailable", %{
    conn: conn
  } do
    org = insert_organization()
    conv = insert_conversation(organization_id: org.id, suspect: true)
    message = insert_message(conversation_id: conv.id)

    {:ok, [_]} =
      Attachments.fetch_for_message(
        message,
        [%{filename: "withheld.txt", url: StubClient.unique_url()}],
        skip: "suspect"
      )

    {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")
    view |> element(~s([data-testid="dismiss-suspect"])) |> render_click()
    html = render_async(view)
    assert html =~ "Some attachments could not be recovered"
    assert has_element?(view, ~s([data-testid="retry-attachments"]))
    view |> element(~s([data-testid="retry-attachments"])) |> render_click()
    assert render_async(view) =~ "Some attachments could not be recovered"
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

    test "renders a stored HTML body as markup with the plain text behind a toggle",
         %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      insert_message(
        conversation_id: conv.id,
        body: "Hello bold",
        html_body: "<p>Hello <b>bold</b></p>"
      )

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      assert has_element?(view, ~s([data-testid="operator-message-html"] b), "bold")
      assert has_element?(view, ~s([data-testid="operator-message-body"]), "Hello bold")
    end

    test "lists attachments with a download link or the reason they were not fetched",
         %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      message = insert_message(conversation_id: conv.id, body: "See attached")

      url = StubClient.unique_url()
      StubClient.put(url, "hello")

      {:ok, [fetched]} =
        Attachments.fetch_for_message(message, [
          %{filename: "notes.txt", content_type: "text/plain", size: 5, content_id: nil, url: url}
        ])

      another_message = insert_message(conversation_id: conv.id)

      {:ok, [skipped]} =
        Attachments.fetch_for_message(
          another_message,
          [
            %{
              filename: "big.zip",
              content_type: "application/zip",
              size: 99,
              content_id: nil,
              url: nil
            }
          ],
          limit_bytes: 0
        )

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      assert has_element?(
               view,
               ~s(a[data-testid="attachment-#{fetched.id}"][href="/operator/attachments/#{fetched.id}"]),
               "notes.txt"
             )

      assert has_element?(view, ~s([data-testid="attachment-#{skipped.id}"]), "big.zip")

      assert has_element?(
               view,
               ~s([data-testid="attachment-skipped-#{skipped.id}"]),
               "not fetched"
             )
    end

    test "shows the detected language in the header", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      {:ok, _} = conv |> Custyard.Conversation.changeset(%{language: "de"}) |> Repo.update()

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")
      assert has_element?(view, ~s([data-testid="conversation-language"]), "de")
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
      refute html =~ "contact-email-status"
    end

    test "flags a contact whose address bounced", %{conn: conn} do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, email: "alice@acme.com")
      contact |> Ecto.Changeset.change(email_status: :bounced) |> Repo.update!()
      conv = insert_conversation(organization_id: org.id, contact_id: contact.id)

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      assert has_element?(view, ~s([data-testid="contact-email-status-bounced"]))
    end
  end

  test "shows an email's cid: image from its own attachment", %{conn: conn} do
    org = insert_organization()
    conv = insert_conversation(organization_id: org.id)

    message =
      insert_message(
        conversation_id: conv.id,
        html_body: ~S|<p>Our logo <img src="cid:logo@acme" alt="Logo" /></p>|
      )

    url = StubClient.unique_url()
    StubClient.put(url, <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "rest">>)

    {:ok, [image]} =
      Attachments.fetch_for_message(message, [
        %{filename: "logo.png", content_type: "image/png", content_id: "<logo@acme>", url: url}
      ])

    {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

    html = view |> element(~s([data-testid="operator-message-html"])) |> render()
    assert html =~ ~s(src="/operator/attachments/#{image.id}/inline")
    refute html =~ "cid:"
  end

  describe "reply recipient in the composer (D5)" do
    setup do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, email: "alice@customer.example")
      conv = insert_conversation(organization_id: org.id, contact_id: contact.id)
      %{conv: conv}
    end

    test "shows the contact's address", %{conn: conn, conv: conv} do
      insert_message(conversation_id: conv.id, source: :email, triage_class: :customer)

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      assert view |> element(~s([data-testid="operator-reply-to"])) |> render() =~
               "alice@customer.example"

      refute has_element?(view, ~s([data-testid="operator-reply-to-override"]))
    end

    test "shows the customer's Reply-To when it overrides the contact", %{
      conn: conn,
      conv: conv
    } do
      insert_message(
        conversation_id: conv.id,
        source: :email,
        triage_class: :customer,
        reply_to: "Billing@Customer.example"
      )

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      assert view |> element(~s([data-testid="operator-reply-to"])) |> render() =~
               "billing@customer.example"

      assert has_element?(view, ~s([data-testid="operator-reply-to-override"]))
    end

    test "ignores a Reply-To on an auto-response", %{conn: conn, conv: conv} do
      insert_message(
        conversation_id: conv.id,
        source: :email,
        triage_class: :auto_response,
        reply_to: "robot@customer.example"
      )

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      assert view |> element(~s([data-testid="operator-reply-to"])) |> render() =~
               "alice@customer.example"
    end

    test "shows no To for a prospect who has not opted in", %{conn: conn} do
      conv = insert_conversation(source: :public_intake)
      insert_prospect(conversation_id: conv.id, email: "p@example.com", notify_on_reply: false)

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      refute has_element?(view, ~s([data-testid="operator-reply-to"]))
    end
  end

  describe "reply-all CC in the composer (D5)" do
    setup do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, email: "alice@customer.example")
      route = insert_inbound_route(organization_id: org.id, source: :lettermint)

      channel =
        insert_inbound_channel(
          inbound_route_id: route.id,
          public_address: "help@acme.example",
          state: :active
        )

      conv =
        insert_conversation(
          organization_id: org.id,
          contact_id: contact.id,
          inbound_channel_id: channel.id
        )

      insert_message(
        conversation_id: conv.id,
        source: :email,
        sender_email: "Alice <alice@customer.example>",
        to_addresses: ["help@acme.example", "ops@customer.example"],
        cc_addresses: ["boss@customer.example", "Help@Acme.example"],
        triage_class: :customer,
        body: "Looping in my team"
      )

      %{conv: conv}
    end

    test "starts from the customer's To and CC minus our own addresses", %{
      conn: conn,
      conv: conv
    } do
      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      assert has_element?(
               view,
               ~s(input[data-testid="operator-reply-cc"][value="boss@customer.example, ops@customer.example"])
             )
    end

    test "typing the body does not freeze untouched CC defaults", %{conn: conn, conv: conv} do
      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      view
      |> form("form[phx-submit=send_reply]",
        body: "Draft",
        cc: "boss@customer.example, ops@customer.example"
      )
      |> render_change()

      insert_message(
        conversation_id: conv.id,
        source: :email,
        sender_email: "alice@customer.example",
        cc_addresses: ["new@customer.example"],
        triage_class: :customer,
        body: "New participants"
      )

      send(view.pid, {:message_added, conv.id})

      assert has_element?(
               view,
               ~s(input[data-testid="operator-reply-cc"][value="new@customer.example"])
             )
    end

    test "an edited CC list is what the reply carries", %{conn: conn, conv: conv} do
      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      view
      |> form("form[phx-submit=send_reply]", body: "Reply to all", cc: "boss@customer.example")
      |> render_submit()

      [reply] =
        Conversations.list_public_messages(conv.id) |> Enum.filter(&(&1.source == :operator))

      assert reply.cc_addresses == ["boss@customer.example"]
      assert has_element?(view, ~s([data-testid="operator-message-cc"]), "boss@customer.example")
    end

    test "an invalid CC address blocks the send with a flash", %{conn: conn, conv: conv} do
      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      html =
        view
        |> form("form[phx-submit=send_reply]", body: "Oops", cc: "not an address")
        |> render_submit()

      assert html =~ "Invalid CC address: not an address"
      assert Enum.all?(Conversations.list_public_messages(conv.id), &(&1.source != :operator))
    end

    test "the composer says when a copy of replies is kept in the mailbox (D4)", %{
      conn: conn,
      conv: conv
    } do
      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")
      refute has_element?(view, ~s([data-testid="composer-archive-copy"]))

      channel = Custyard.InboundChannels.get_channel!(conv.inbound_channel_id)
      {:ok, _} = Custyard.InboundChannels.update_channel(channel, %{archive_copy: true})

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      assert has_element?(
               view,
               ~s([data-testid="composer-archive-copy"]),
               "a copy is kept in help@acme.example"
             )
    end

    test "prospect conversations have no CC field", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id, source: :public_intake)

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")
      refute has_element?(view, ~s([data-testid="operator-reply-cc"]))
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

    test "delivery indicator shows delivered once the status webhook confirms", %{conn: conn} do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, email: "live@customer.com")
      conv = insert_conversation(organization_id: org.id, contact_id: contact.id)

      insert_message(
        conversation_id: conv.id,
        source: :operator,
        body: "Confirmed by the provider",
        delivery_status: :delivered
      )

      {:ok, _view, html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      assert html =~ "delivery-status-delivered"
      assert html =~ "Delivered to recipient"
      refute html =~ "delivery-status-sent"
    end

    test "delivery indicator shows suppressed distinctly from bounced", %{conn: conn} do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, email: "live@customer.com")
      conv = insert_conversation(organization_id: org.id, contact_id: contact.id)

      insert_message(
        conversation_id: conv.id,
        source: :operator,
        body: "Refused by the provider",
        delivery_status: :suppressed
      )

      {:ok, _view, html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      assert html =~ "delivery-status-suppressed"
      assert html =~ "Suppressed by email provider"
      refute html =~ "delivery-status-bounced"
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
      |> put_operator_session(operator.id)
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

    test "open unlinked prospect loses access when linked to another organization" do
      own = insert_organization()
      foreign = insert_organization()
      contact = insert_contact(organization_id: foreign.id, email: "known@foreign.example")
      operator = insert_scoped_operator(own.id, "admin")
      conv = insert_conversation(organization_id: nil, source: :public_intake, state: :active)
      insert_prospect(conversation_id: conv.id)
      conn = conn_for_operator(operator)

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")
      assert {:ok, _linked} = Custyard.Intake.capture_email(conv, contact.email)

      assert_redirect(view, "/operator")
      refute Enum.any?(Conversations.list_public_messages(conv.id), &(&1.source == :operator))
    end

    test "stale unlinked socket cannot reply when linkage has no broadcast" do
      own = insert_organization()
      foreign = insert_organization()
      operator = insert_scoped_operator(own.id, "admin")
      conv = insert_conversation(organization_id: nil, source: :public_intake, state: :active)
      conn = conn_for_operator(operator)
      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      conv
      |> Ecto.Changeset.change(organization_id: foreign.id)
      |> Repo.update!()

      view
      |> form("form[phx-submit=send_reply]", body: "Unauthorized reply")
      |> render_submit()

      assert_redirect(view, "/operator")
      refute Enum.any?(Conversations.list_public_messages(conv.id), &(&1.source == :operator))
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

  describe "stale task rows" do
    test "acting on a deleted task shows a notice instead of crashing", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      {:ok, task} = Conversations.create_task(%{title: "Gone soon", conversation_id: conv.id})

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      # Deleted from another session: nothing tells this view
      {:ok, _} = Conversations.delete_task(task)

      html = render_click(view, "toggle_task", %{"id" => "#{task.id}"})
      assert html =~ "no longer exists"
      assert Process.alive?(view.pid)

      html = render_click(view, "delete_task", %{"id" => "#{task.id}"})
      assert html =~ "no longer exists"
      assert Process.alive?(view.pid)
    end

    test "a task of another conversation cannot be edited through this view", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      other = insert_conversation(organization_id: org.id)
      {:ok, task} = Conversations.create_task(%{title: "Elsewhere", conversation_id: other.id})

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      html = render_click(view, "toggle_task", %{"id" => "#{task.id}"})
      assert html =~ "no longer exists"
      assert Conversations.get_task!(task.id).state == :open
    end
  end

  describe "inbound channel surfaces" do
    test "header shows the channel badge when the conversation arrived on a channel", %{
      conn: conn
    } do
      org = insert_organization()

      channel =
        insert_inbound_channel(
          organization_id: org.id,
          public_address: "support@acme.example.com",
          state: :active
        )

      conv = insert_conversation(organization_id: org.id, inbound_channel_id: channel.id)

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      assert view |> element("[data-testid=conversation-channel]") |> render() =~
               "support@acme.example.com"

      refute render(view) =~ channel.ingress_token
    end

    test "no channel badge without a channel", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      refute has_element?(view, "[data-testid=conversation-channel]")
      refute has_element?(view, "[data-testid=conversation-suspect-badge]")
    end

    test "suspect badge can be dismissed", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      {:ok, _} = Conversations.set_suspect(conv, true)

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      assert has_element?(view, "[data-testid=conversation-suspect-badge]")
      view |> element("[data-testid=dismiss-suspect]") |> render_click()

      refute has_element?(view, "[data-testid=conversation-suspect-badge]")
      refute Conversations.get_conversation!(conv.id).suspect
    end

    test "email messages carry a collapsed details line with envelope data", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      msg =
        insert_message(
          conversation_id: conv.id,
          source: :email,
          sender_email: "alice@customer.example",
          to_addresses: ["support@acme.example.com"],
          cc_addresses: ["bob@customer.example"],
          reply_to: "alice-replies@customer.example",
          spam_score: 1.5,
          authentication: %{
            "dkim" => "pass",
            "dkim_domain" => "customer.example",
            "spf" => "fail"
          }
        )

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      details =
        view
        |> element("[data-testid=operator-message-#{msg.id}] [data-testid=message-details]")
        |> render()

      assert details =~ "<details"
      assert details =~ "alice@customer.example"
      assert details =~ "support@acme.example.com"
      assert details =~ "bob@customer.example"

      assert view |> element("[data-testid=message-reply-to]") |> render() =~
               "alice-replies@customer.example"

      badge = view |> element("[data-testid=message-auth-badge]") |> render()
      assert badge =~ "DKIM pass"
      assert badge =~ "customer.example"
      assert badge =~ ~s(data-auth-result="pass")
    end

    test "reply-to equal to the sender is not repeated", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      insert_message(
        conversation_id: conv.id,
        source: :email,
        sender_email: "alice@customer.example",
        reply_to: "Alice@Customer.example",
        authentication: %{"dkim" => "fail", "dkim_domain" => "customer.example"}
      )

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      refute has_element?(view, "[data-testid=message-reply-to]")
      refute has_element?(view, "[data-testid=message-cc]")

      badge = view |> element("[data-testid=message-auth-badge]") |> render()
      assert badge =~ "DKIM fail"
      assert badge =~ ~s(data-auth-result="fail")
    end

    test "authentication badge variants: unauthenticated and no data", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      none =
        insert_message(
          conversation_id: conv.id,
          source: :email,
          authentication: %{"spf" => "pass"}
        )

      missing = insert_message(conversation_id: conv.id, source: :email, authentication: nil)

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      assert view
             |> element(
               "[data-testid=operator-message-#{none.id}] [data-testid=message-auth-badge]"
             )
             |> render() =~ "unauthenticated"

      assert view
             |> element(
               "[data-testid=operator-message-#{missing.id}] [data-testid=message-auth-badge]"
             )
             |> render() =~ "no auth data"
    end

    test "operator and portal messages have no details line", %{conn: conn} do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      insert_message(conversation_id: conv.id, source: :operator, body: "Reply")
      insert_message(conversation_id: conv.id, source: :portal, body: "Portal")

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      refute has_element?(view, "[data-testid=message-details]")
      refute has_element?(view, "[data-testid=message-auth-badge]")
    end

    test "auto-responses render as muted system messages, suspect messages get a tag", %{
      conn: conn
    } do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      auto =
        insert_message(
          conversation_id: conv.id,
          source: :email,
          triage_class: :auto_response,
          body: "I am out of the office"
        )

      suspect =
        insert_message(
          conversation_id: conv.id,
          source: :email,
          triage_class: :suspect,
          body: "Urgent wire transfer"
        )

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      auto_html = view |> element("[data-testid=operator-message-#{auto.id}]") |> render()
      assert auto_html =~ ~s(data-testid="message-system-tag")
      assert auto_html =~ "auto-reply"
      assert auto_html =~ "italic"
      assert has_element?(view, "[data-testid=operator-message-delete-#{auto.id}]")

      suspect_html = view |> element("[data-testid=operator-message-#{suspect.id}]") |> render()
      assert suspect_html =~ ~s(data-testid="message-suspect-tag")
      refute suspect_html =~ "message-system-tag"
    end

    test "composer shows the channel From identity", %{conn: conn} do
      org = insert_organization(name: "Acme")

      channel =
        insert_inbound_channel(
          organization_id: org.id,
          public_address: "support@acme.example.com",
          display_name: "Acme Support",
          state: :active
        )

      conv = insert_conversation(organization_id: org.id, inbound_channel_id: channel.id)

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      identity = view |> element("[data-testid=composer-from-identity]") |> render()
      assert identity =~ "Replies go out as"
      assert identity =~ "Acme Support"
      assert identity =~ "support@acme.example.com"
      assert identity =~ ~s(data-identity-source="channel")
    end

    test "composer falls back to the platform sender for public intake", %{conn: conn} do
      conv = insert_conversation(source: :public_intake)

      {:ok, view, _html} = live(conn, ~p"/operator/conversation/#{conv.id}")

      identity = view |> element("[data-testid=composer-from-identity]") |> render()
      assert identity =~ ~s(data-identity-source="platform")

      assert identity =~
               Application.get_env(:custyard, :email_from_address, "support@custyard.local")
    end
  end
end
