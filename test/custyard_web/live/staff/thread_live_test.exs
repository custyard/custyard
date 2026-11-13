defmodule CustyardWeb.Staff.ThreadLiveTest do
  use CustyardWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Custyard.Factory

  alias Custyard.Attachments.StubClient
  alias Custyard.Email.{DeliveryStatus, Outbound}
  alias Custyard.{Attachments, Threads, StaffAccount, Repo, Scoring}

  setup %{conn: conn} do
    # Create and authenticate a staff
    {:ok, staff} =
      %StaffAccount{}
      |> StaffAccount.changeset(%{
        role: "admin",
        tenant_id: Process.get(:factory_tenant_id),
        email: "test@example.com",
        password: "password123"
      })
      |> Repo.insert()

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> put_staff_session(staff.id)

    sending_channel = insert_inbound_channel(state: :active)
    {:ok, conn: conn, staff: staff, sending_channel: sending_channel}
  end

  test "clearing suspect starts recovery and retains an explicit retry when unavailable", %{
    conn: conn
  } do
    org = insert_organization()
    conv = insert_thread(organization_id: org.id, suspect: true)
    message = insert_message(thread_id: conv.id)

    {:ok, [_]} =
      Attachments.fetch_for_message(
        message,
        [%{filename: "withheld.txt", url: StubClient.unique_url()}],
        skip: "suspect"
      )

    {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")
    view |> element(~s([data-testid="dismiss-suspect"])) |> render_click()
    html = render_async(view)
    assert html =~ "Some attachments could not be recovered"
    assert has_element?(view, ~s([data-testid="retry-attachments"]))
    view |> element(~s([data-testid="retry-attachments"])) |> render_click()
    assert render_async(view) =~ "Some attachments could not be recovered"
  end

  describe "mount/3" do
    test "renders thread view", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)
      insert_message(thread_id: conv.id, body: "Hello from customer")

      {:ok, view, html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert html =~ conv.subject
      assert html =~ "Hello from customer"

      assert has_element?(
               view,
               "[data-testid=staff-thread-customer-link][href='/app/customers/#{org.public_id}']",
               org.name
             )

      assert has_element?(
               view,
               "[data-testid=staff-sidebar-org-link][href='/app/customers/#{org.public_id}']",
               org.name
             )
    end

    test "renders a stored HTML body as markup with the plain text behind a toggle",
         %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)

      insert_message(
        thread_id: conv.id,
        body: "Hello bold",
        html_body: "<p>Hello <b>bold</b></p>"
      )

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert has_element?(view, ~s([data-testid="staff-message-html"] b), "bold")
      assert has_element?(view, ~s([data-testid="staff-message-body"]), "Hello bold")
    end

    test "lists attachments with a download link or the reason they were not fetched",
         %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)
      message = insert_message(thread_id: conv.id, body: "See attached")

      url = StubClient.unique_url()
      StubClient.put(url, "hello")

      {:ok, [fetched]} =
        Attachments.fetch_for_message(message, [
          %{filename: "notes.txt", content_type: "text/plain", size: 5, content_id: nil, url: url}
        ])

      another_message = insert_message(thread_id: conv.id)

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

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert has_element?(
               view,
               ~s(a[data-testid="attachment-#{fetched.id}"][href="/app/attachments/#{fetched.id}"]),
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
      conv = insert_thread(organization_id: org.id)
      {:ok, _} = conv |> Custyard.Thread.changeset(%{language: "de"}) |> Repo.update()

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")
      assert has_element?(view, ~s([data-testid="thread-language"]), "de")
    end

    test "transitions new thread to active on view", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id, state: :new)

      {:ok, _view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      updated = Custyard.Repo.get!(Custyard.Thread, conv.id)
      assert updated.state == :active
    end

    test "shows score breakdown", %{conn: conn} do
      org = insert_organization(tier: :enterprise)
      conv = insert_thread(organization_id: org.id, state: :new, urgency: :urgent)
      Scoring.calculate_and_cache(conv.id)

      {:ok, _view, html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert html =~ "Score breakdown"
      assert html =~ "tier"
      assert html =~ "urgency"
    end

    test "shows organization and contact info", %{conn: conn} do
      org = insert_organization(name: "Acme Corp", tier: :enterprise)
      contact = insert_contact(organization_id: org.id, name: "Alice", email: "alice@acme.com")
      conv = insert_thread(organization_id: org.id, contact_id: contact.id)

      {:ok, _view, html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert html =~ "Acme Corp"
      assert html =~ "Alice"
      assert html =~ "alice@acme.com"
      refute html =~ "contact-email-status"
    end

    test "flags a contact whose address bounced", %{conn: conn} do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, email: "alice@acme.com")
      contact |> Ecto.Changeset.change(email_status: :bounced) |> Repo.update!()
      conv = insert_thread(organization_id: org.id, contact_id: contact.id)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert has_element?(view, ~s([data-testid="contact-email-status-bounced"]))
    end
  end

  test "shows an email's cid: image from its own attachment", %{conn: conn} do
    org = insert_organization()
    conv = insert_thread(organization_id: org.id)

    message =
      insert_message(
        thread_id: conv.id,
        html_body: ~S|<p>Our logo <img src="cid:logo@acme" alt="Logo" /></p>|
      )

    url = StubClient.unique_url()
    StubClient.put(url, <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, "rest">>)

    {:ok, [image]} =
      Attachments.fetch_for_message(message, [
        %{filename: "logo.png", content_type: "image/png", content_id: "<logo@acme>", url: url}
      ])

    {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

    html = view |> element(~s([data-testid="staff-message-html"])) |> render()
    assert html =~ ~s(src="/app/attachments/#{image.id}/inline")
    refute html =~ "cid:"
  end

  describe "reply recipient in the composer (D5)" do
    setup do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, email: "alice@customer.example")
      conv = insert_thread(organization_id: org.id, contact_id: contact.id)
      %{conv: conv}
    end

    test "shows the contact's address before a customer message arrives", %{
      conn: conn,
      conv: conv
    } do
      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert view |> element(~s([data-testid="staff-reply-to"])) |> render() =~
               "alice@customer.example"

      refute has_element?(view, ~s([data-testid="staff-reply-to-override"]))
    end

    test "shows the latest participant instead of the original contact", %{conn: conn, conv: conv} do
      insert_message(
        thread_id: conv.id,
        source: :email,
        triage_class: :customer,
        sender_email: "bob@customer.example"
      )

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert view |> element(~s([data-testid="staff-reply-to"])) |> render() =~
               "bob@customer.example"

      assert has_element?(
               view,
               ~s([data-testid="staff-reply-to-override"]),
               "latest customer message"
             )
    end

    test "shows the customer's Reply-To when it overrides the contact", %{
      conn: conn,
      conv: conv
    } do
      insert_message(
        thread_id: conv.id,
        source: :email,
        triage_class: :customer,
        reply_to: "Billing@Customer.example"
      )

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert view |> element(~s([data-testid="staff-reply-to"])) |> render() =~
               "billing@customer.example"

      assert has_element?(view, ~s([data-testid="staff-reply-to-override"]))
    end

    test "ignores a Reply-To on an auto-response", %{conn: conn, conv: conv} do
      insert_message(
        thread_id: conv.id,
        source: :email,
        triage_class: :auto_response,
        reply_to: "robot@customer.example"
      )

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert view |> element(~s([data-testid="staff-reply-to"])) |> render() =~
               "alice@customer.example"
    end

    test "shows an opted-in prospect's address, not as a Reply-To", %{conn: conn} do
      conv = insert_thread(source: :public_intake)
      insert_prospect(thread_id: conv.id, email: "p@example.com", notify_on_reply: true)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert view |> element(~s([data-testid="staff-reply-to"])) |> render() =~
               "p@example.com"

      refute has_element?(view, ~s([data-testid="staff-reply-to-override"]))
    end

    test "shows no To for a prospect who has not opted in", %{conn: conn} do
      conv = insert_thread(source: :public_intake)
      insert_prospect(thread_id: conv.id, email: "p@example.com", notify_on_reply: false)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      refute has_element?(view, ~s([data-testid="staff-reply-to"]))
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
        insert_thread(
          organization_id: org.id,
          contact_id: contact.id,
          inbound_channel_id: channel.id
        )

      insert_message(
        thread_id: conv.id,
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
      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert has_element?(
               view,
               ~s(input[data-testid="staff-reply-cc"][value="boss@customer.example, ops@customer.example"])
             )
    end

    test "typing the body does not freeze untouched CC defaults", %{conn: conn, conv: conv} do
      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      view
      |> form("form[phx-submit=send_reply]",
        body: "Draft",
        cc: "boss@customer.example, ops@customer.example"
      )
      |> render_change()

      insert_message(
        thread_id: conv.id,
        source: :email,
        sender_email: "alice@customer.example",
        cc_addresses: ["new@customer.example"],
        triage_class: :customer,
        body: "New participants"
      )

      send(view.pid, {:message_added, conv.id})

      assert has_element?(
               view,
               ~s(input[data-testid="staff-reply-cc"][value="new@customer.example"])
             )
    end

    test "an edited CC list is what the reply carries", %{conn: conn, conv: conv} do
      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      view
      |> form("form[phx-submit=send_reply]", body: "Reply to all", cc: "boss@customer.example")
      |> render_submit()

      [reply] =
        Threads.list_public_messages(conv.id) |> Enum.filter(&(&1.source == :staff))

      assert reply.cc_addresses == ["boss@customer.example"]
      assert has_element?(view, ~s([data-testid="staff-message-cc"]), "boss@customer.example")
    end

    test "an invalid CC address blocks the send with a flash", %{conn: conn, conv: conv} do
      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      html =
        view
        |> form("form[phx-submit=send_reply]", body: "Oops", cc: "not an address")
        |> render_submit()

      assert html =~ "Invalid CC address: not an address"
      assert Enum.all?(Threads.list_public_messages(conv.id), &(&1.source != :staff))
    end

    test "the composer says when a copy of replies is kept in the mailbox (D4)", %{
      conn: conn,
      conv: conv
    } do
      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")
      refute has_element?(view, ~s([data-testid="composer-archive-copy"]))

      channel = Custyard.InboundChannels.get_channel!(conv.inbound_channel_id)
      {:ok, _} = Custyard.InboundChannels.update_channel(channel, %{archive_copy: true})

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      # In the summary, so it is seen while the recipient details are closed.
      assert has_element?(
               view,
               ~s(details#composer-recipients > summary [data-testid="composer-archive-copy"]),
               "a copy is kept in help@acme.example"
             )
    end

    test "prospect threads have no CC field", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id, source: :public_intake)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")
      refute has_element?(view, ~s([data-testid="staff-reply-cc"]))
    end
  end

  describe "handle_event send_reply" do
    test "creates a reply message", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      view
      |> form("form[phx-submit=send_reply]", body: "This is my reply")
      |> render_submit()

      messages = Threads.list_public_messages(conv.id)
      assert length(messages) == 1
      assert hd(messages).body == "This is my reply"
      assert hd(messages).source == :staff
    end

    test "reply message has delivery_status pending", %{conn: conn} do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, email: "pending@customer.com")
      conv = insert_thread(organization_id: org.id, contact_id: contact.id)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      view
      |> form("form[phx-submit=send_reply]", body: "Outbound reply")
      |> render_submit()

      [message] = Threads.list_public_messages(conv.id)
      # async delivery is disabled via test config, so status stays :pending
      assert message.delivery_status == :pending
    end

    test "reply message has a generated RFC 5322 message_id", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      view
      |> form("form[phx-submit=send_reply]", body: "Reply with message ID")
      |> render_submit()

      [message] = Threads.list_public_messages(conv.id)
      assert message.message_id != nil
      # RFC 5322 Message-ID format: <unique.cN@domain>
      assert message.message_id =~ ~r/^<.+\.c\d+@.+>$/
    end

    test "reply message has in_reply_to from last customer message", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)
      # Insert a customer message with a known message_id
      insert_message(
        thread_id: conv.id,
        source: :email,
        message_id: "<customer-msg-123@example.com>",
        body: "Customer question"
      )

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      view
      |> form("form[phx-submit=send_reply]", body: "Reply to thread")
      |> render_submit()

      messages = Threads.list_public_messages(conv.id)
      reply = Enum.find(messages, &(&1.source == :staff))
      assert reply.in_reply_to == "<customer-msg-123@example.com>"
    end

    test "reply threads to the latest of multiple customer messages", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)

      insert_message(
        thread_id: conv.id,
        source: :email,
        message_id: "<older-msg@example.com>",
        body: "First question"
      )

      insert_message(
        thread_id: conv.id,
        source: :email,
        message_id: "<newer-msg@example.com>",
        body: "Follow-up question"
      )

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      view
      |> form("form[phx-submit=send_reply]", body: "Answering the follow-up")
      |> render_submit()

      messages = Threads.list_public_messages(conv.id)
      reply = Enum.find(messages, &(&1.source == :staff))
      assert reply.in_reply_to == "<newer-msg@example.com>"
    end

    test "reply message in_reply_to is nil when no prior customer messages", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      view
      |> form("form[phx-submit=send_reply]", body: "First message in thread")
      |> render_submit()

      [message] = Threads.list_public_messages(conv.id)
      assert message.in_reply_to == nil
    end

    test "clears reply input after sending", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

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
      conv = insert_thread(organization_id: org.id)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      view
      |> form("form[phx-submit=send_reply]", body: "")
      |> render_submit()

      messages = Threads.list_public_messages(conv.id)
      assert messages == []
    end

    test "warns the staff when the contact has no email address", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id, contact_id: nil)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      html =
        view
        |> form("form[phx-submit=send_reply]", body: "Reply into the void")
        |> render_submit()

      # The reply is still recorded, but the staff sees the warning
      assert html =~ "no email address"
      assert [_message] = Threads.list_public_messages(conv.id)
    end
  end

  describe "delivery status updates" do
    test "delivery indicator updates live when async delivery resolves", %{conn: conn} do
      org = insert_organization()
      configure_tenant_email(org.tenant_id)
      contact = insert_contact(organization_id: org.id, email: "live@customer.com")
      conv = insert_thread(organization_id: org.id, contact_id: contact.id)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      html =
        view
        |> form("form[phx-submit=send_reply]", body: "Watch me get delivered")
        |> render_submit()

      assert html =~ "delivery-status-pending"

      # Resolve the delivery the async task would normally perform; the
      # message_updated broadcast must refresh the indicator in the view.
      [message] = Threads.list_public_messages(conv.id)
      {:ok, _} = Outbound.deliver(message)

      html = render(view)
      refute html =~ "delivery-status-pending"
      assert html =~ "delivery-status-sent"
    end

    test "delivery indicator shows delivered once the status webhook confirms", %{conn: conn} do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, email: "live@customer.com")
      conv = insert_thread(organization_id: org.id, contact_id: contact.id)

      insert_message(
        thread_id: conv.id,
        source: :staff,
        body: "Confirmed by the provider",
        delivery_status: :delivered
      )

      {:ok, _view, html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert html =~ "delivery-status-delivered"
      assert html =~ "Delivered to recipient"
      refute html =~ "delivery-status-sent"
    end

    test "delivery indicator follows the customer and lists a failed CC separately", %{
      conn: conn
    } do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, email: "live@customer.com")
      conv = insert_thread(organization_id: org.id, contact_id: contact.id)

      message =
        insert_message(
          thread_id: conv.id,
          source: :staff,
          body: "Reached the customer, not the CC",
          delivery_status: :delivered,
          lettermint_message_id: "lm-live-cc",
          to_addresses: ["live@customer.com"],
          cc_addresses: ["boss@customer.com"]
        )

      insert_recipient_status(
        message_id: message.id,
        address: "live@customer.com",
        role: :to,
        status: :delivered
      )

      {:ok, view, html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert html =~ "delivery-status-delivered"
      refute html =~ "delivery-recipient-failure"

      # The CC bounce arrives by webhook; the broadcast refreshes the thread.
      assert {:ok, :updated, _} =
               DeliveryStatus.apply_event(
                 %{
                   "id" => "evt-cc",
                   "event" => "message.hard_bounced",
                   "timestamp" => "2026-10-20T12:00:00Z",
                   "data" => %{"message_id" => "lm-live-cc", "recipient" => "boss@customer.com"}
                 },
                 tenant_id: org.tenant_id
               )

      html = render(view)
      assert html =~ "delivery-status-delivered"
      refute html =~ "delivery-status-bounced"
      assert html =~ "delivery-recipient-failure"
      assert html =~ "Not delivered to CC boss@customer.com: bounced"
    end

    test "delivery indicator shows suppressed distinctly from bounced", %{conn: conn} do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, email: "live@customer.com")
      conv = insert_thread(organization_id: org.id, contact_id: contact.id)

      insert_message(
        thread_id: conv.id,
        source: :staff,
        body: "Refused by the provider",
        delivery_status: :suppressed
      )

      {:ok, _view, html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert html =~ "delivery-status-suppressed"
      assert html =~ "Suppressed by email provider"
      refute html =~ "delivery-status-bounced"
    end

    test "delivery indicator shows failed when delivery fails", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id, contact_id: nil)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      view
      |> form("form[phx-submit=send_reply]", body: "Undeliverable")
      |> render_submit()

      [message] = Threads.list_public_messages(conv.id)
      {:error, :no_recipient_email, _} = Outbound.deliver(message)

      html = render(view)
      refute html =~ "delivery-status-pending"
      assert html =~ "delivery-status-failed"
    end
  end

  describe "delete message" do
    test "staff soft-deletes a message and the tombstone replaces the body", %{
      conn: conn,
      staff: staff
    } do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)
      message = insert_message(thread_id: conv.id, body: "Sensitive customer detail")

      {:ok, view, html} = live(conn, ~p"/app/threads/#{conv.id}")
      assert html =~ "Sensitive customer detail"

      html =
        view
        |> element(~s([data-testid="staff-message-delete-#{message.id}"]))
        |> render_click()

      assert html =~ "staff-message-tombstone"
      assert html =~ "This message was deleted"
      refute html =~ "Sensitive customer detail"

      # Soft delete only: the row keeps its body, stamped with the deleter.
      reloaded = Repo.get!(Custyard.Message, message.id)
      assert reloaded.body == "Sensitive customer detail"
      assert %DateTime{} = reloaded.deleted_at
      assert reloaded.deleted_by_staff_id == staff.id
    end

    test "delete affordance requires confirmation and disappears once deleted", %{
      conn: conn,
      staff: staff
    } do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)
      message = insert_message(thread_id: conv.id, body: "Doomed message")

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert view
             |> element(~s([data-testid="staff-message-delete-#{message.id}"]))
             |> render() =~ "data-confirm"

      {:ok, _} = Threads.soft_delete_message(message, staff)

      # The message_updated broadcast refreshes the open view: tombstone in,
      # delete affordance gone.
      html = render(view)
      assert html =~ "This message was deleted"
      refute html =~ "Doomed message"
      refute has_element?(view, ~s([data-testid="staff-message-delete-#{message.id}"]))
    end

    test "deleting an unknown message id flashes an error and deletes nothing", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)
      other_conv = insert_thread(organization_id: org.id)
      foreign = insert_message(thread_id: other_conv.id, body: "Other thread")

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      # An id from another thread is out of scope for this view.
      html = render_click(view, "delete_message", %{"id" => to_string(foreign.id)})

      assert html =~ "Message not found"
      assert Repo.get!(Custyard.Message, foreign.id).deleted_at == nil
    end
  end

  describe "consent-withheld replies (public intake)" do
    test "delivery indicator shows withheld", %{conn: conn} do
      conv = insert_thread(source: :public_intake)

      insert_prospect(
        thread_id: conv.id,
        email: "prospect@example.com",
        notify_on_reply: false
      )

      insert_message(
        thread_id: conv.id,
        source: :staff,
        sender_email: nil,
        body: "Recorded but not emailed",
        delivery_status: :withheld
      )

      {:ok, _view, html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert html =~ "delivery-status-withheld"
      assert html =~ "Not emailed"
    end

    test "reply without prospect consent shows the advisory and records withheld", %{conn: conn} do
      conv = insert_thread(source: :public_intake)

      insert_prospect(
        thread_id: conv.id,
        email: "prospect@example.com",
        notify_on_reply: false
      )

      {:ok, view, html} = live(conn, ~p"/app/threads/#{conv.id}")
      assert html =~ "staff-reply-consent-advisory"

      html =
        view
        |> form("form[phx-submit=send_reply]", body: "Reply without consent")
        |> render_submit()

      [message] = Threads.list_public_messages(conv.id)
      assert message.delivery_status == :withheld
      assert html =~ "delivery-status-withheld"
      refute html =~ "delivery-status-pending"
    end

    test "advisory is absent when the prospect has opted in", %{conn: conn} do
      conv = insert_thread(source: :public_intake)

      insert_prospect(
        thread_id: conv.id,
        email: "prospect@example.com",
        notify_on_reply: true
      )

      {:ok, _view, html} = live(conn, ~p"/app/threads/#{conv.id}")

      refute html =~ "staff-reply-consent-advisory"
    end

    test "advisory is absent when no email was captured", %{conn: conn} do
      conv = insert_thread(source: :public_intake)

      # Prospect row without a captured email: there is no opt-in to speak
      # of, so the opt-in advisory would misstate the cause — the "no reply
      # channel" state is conveyed by the reply-channel badge instead.
      insert_prospect(thread_id: conv.id)

      {:ok, _view, html} = live(conn, ~p"/app/threads/#{conv.id}")

      refute html =~ "staff-reply-consent-advisory"
    end

    test "advisory is absent on non-intake threads", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)

      {:ok, _view, html} = live(conn, ~p"/app/threads/#{conv.id}")

      refute html =~ "staff-reply-consent-advisory"
    end
  end

  describe "prospect message via label" do
    test "shows the masked prospect email when one was captured", %{conn: conn} do
      conv = insert_thread(source: :public_intake)
      insert_prospect(thread_id: conv.id, email: "prospect@example.com")

      # sender_email is nil on real prospect messages (see Intake) — the via
      # label is the only place the captured email should surface.
      insert_message(thread_id: conv.id, source: :prospect, sender_email: nil, body: "Hi")

      {:ok, _view, html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert html =~ "via prospect pro***@example.com"
      refute html =~ "prospect@example.com"
    end

    test "masks all but the first char when the local part is 3 chars or fewer", %{conn: conn} do
      conv = insert_thread(source: :public_intake)
      insert_prospect(thread_id: conv.id, email: "abc@example.com")
      insert_message(thread_id: conv.id, source: :prospect, sender_email: nil, body: "Hi")

      {:ok, _view, html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert html =~ "via prospect a***@example.com"
      refute html =~ "abc@example.com"
    end

    test "keeps plain via prospect when no email was captured", %{conn: conn} do
      conv = insert_thread(source: :public_intake)
      insert_prospect(thread_id: conv.id)
      insert_message(thread_id: conv.id, source: :prospect, sender_email: nil, body: "Hi")

      {:ok, _view, html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert html =~ "via prospect"
      refute html =~ "via prospect ***"
      refute html =~ "***@"
    end
  end

  describe "handle_event add_note" do
    test "creates an internal note", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      view |> element("[data-testid=composer-mode-note]") |> render_click()

      view
      |> form("form[phx-submit=add_note]", body: "Internal note content")
      |> render_submit()

      # Note should appear in view
      html = render(view)
      assert html =~ "Internal note content"
      assert html =~ "internal note"
      assert [note] = Repo.all(Ecto.assoc(conv, :messages))
      assert note.is_internal_note
      assert is_nil(note.delivery_status)
      assert Threads.list_public_messages(conv.id) == []
    end

    test "tells open attention queues, which preview the note", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id, state: :active)
      thread_id = conv.id

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")
      view |> element("[data-testid=composer-mode-note]") |> render_click()

      Phoenix.PubSub.subscribe(Custyard.PubSub, "threads")

      view
      |> form("form[phx-submit=add_note]", body: "Asked finance")
      |> render_submit()

      assert_receive {:thread_updated, ^thread_id}
    end
  end

  describe "composer audience and drafts" do
    test "switching modes preserves separate drafts and hides customer recipients for notes", %{
      conn: conn
    } do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)
      {:ok, view, _} = live(conn, ~p"/app/threads/#{conv.id}")

      assert has_element?(view, "#staff-reply-form")
      refute has_element?(view, "#staff-note-form")

      view
      |> form("#staff-reply-form", body: "Customer draft", cc: "copy@example.com")
      |> render_change()

      view |> element("[data-testid=composer-mode-note]") |> render_click()
      assert has_element?(view, "[data-testid=composer-audience]", "only your team can see this")
      assert has_element?(view, "[data-testid=composer-mode-note][aria-pressed=true]")
      refute has_element?(view, "#staff-reply-form")
      refute has_element?(view, "[data-testid=staff-reply-cc]")
      refute has_element?(view, "[data-testid=composer-from-identity]")

      assert view
             |> element("#staff-note-input")
             |> render()
             |> Floki.parse_fragment!()
             |> Floki.text() == ""

      view |> form("#staff-note-form", body: "Private draft\nSecond line") |> render_change()
      view |> element("[data-testid=composer-mode-reply]") |> render_click()
      assert has_element?(view, "[data-testid=composer-audience]", "visible to the customer")
      assert view |> element("#staff-reply-textarea") |> render() =~ "Customer draft"
      refute view |> element("#staff-reply-textarea") |> render() =~ "Private draft"
      assert has_element?(view, "[data-testid=staff-reply-cc][value='copy@example.com']")

      view |> element("[data-testid=composer-mode-note]") |> render_click()
      assert view |> element("#staff-note-input") |> render() =~ "Private draft"
      view |> form("#staff-note-form", body: "Private draft\nSecond line") |> render_submit()

      assert view
             |> element("#staff-note-input")
             |> render()
             |> Floki.parse_fragment!()
             |> Floki.text() == ""

      assert has_element?(view, "[data-testid=composer-mode-note][aria-pressed=true]")
      view |> element("[data-testid=composer-mode-reply]") |> render_click()
      assert view |> element("#staff-reply-textarea") |> render() =~ "Customer draft"

      assert [%{is_internal_note: true, body: "Private draft\nSecond line"}] =
               Repo.all(Ecto.assoc(conv, :messages))

      assert Threads.list_public_messages(conv.id) == []
    end

    test "sending a customer reply leaves the private draft untouched", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)
      {:ok, view, _} = live(conn, ~p"/app/threads/#{conv.id}")

      view |> element("[data-testid=composer-mode-note]") |> render_click()
      view |> form("#staff-note-form", body: "Do not share this") |> render_change()
      view |> element("[data-testid=composer-mode-reply]") |> render_click()
      view |> form("#staff-reply-form", body: "Customer response") |> render_submit()

      assert [%{body: "Customer response", is_internal_note: false}] =
               Threads.list_public_messages(conv.id)

      assert has_element?(view, "[data-testid=composer-mode-reply][aria-pressed=true]")
      view |> element("[data-testid=composer-mode-note]") |> render_click()
      assert view |> element("#staff-note-input") |> render() =~ "Do not share this"
    end

    test "the server rejects submissions for the inactive mode", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)
      {:ok, view, _} = live(conn, ~p"/app/threads/#{conv.id}")

      render_submit(view, "add_note", %{"body" => "Wrong mode"})
      assert Repo.all(Ecto.assoc(conv, :messages)) == []
      view |> element("[data-testid=composer-mode-note]") |> render_click()
      render_submit(view, "send_reply", %{"body" => "Must stay private"})
      assert Repo.all(Ecto.assoc(conv, :messages)) == []
      render_click(view, "select_composer_mode", %{"mode" => "invalid"})
      assert has_element?(view, "[data-testid=composer-mode-note][aria-pressed=true]")
    end
  end

  describe "handle_event set_state" do
    test "sets thread to waiting", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id, state: :active)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      view
      |> element("[phx-click=set_state][phx-value-state=waiting]")
      |> render_click()

      updated = Custyard.Repo.get!(Custyard.Thread, conv.id)
      assert updated.state == :waiting
    end

    test "sets thread to resolved", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id, state: :active)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      view
      |> element("[phx-click=set_state][phx-value-state=resolved]")
      |> render_click()

      updated = Custyard.Repo.get!(Custyard.Thread, conv.id)
      assert updated.state == :resolved
    end

    test "waiting button toggles: clicking on a waiting thread reverts to active", %{
      conn: conn
    } do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id, state: :waiting)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      # The button reflects the current state and offers the reverse transition
      assert has_element?(
               view,
               "[data-testid=staff-state-waiting][phx-value-state=active][aria-pressed=true]"
             )

      view
      |> element("[data-testid=staff-state-waiting]")
      |> render_click()

      updated = Custyard.Repo.get!(Custyard.Thread, conv.id)
      assert updated.state == :active
    end

    test "waiting button reflects the toggled state after clicking", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id, state: :active)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert has_element?(
               view,
               "[data-testid=staff-state-waiting][phx-value-state=waiting][aria-pressed=false]"
             )

      view
      |> element("[data-testid=staff-state-waiting]")
      |> render_click()

      assert has_element?(
               view,
               "[data-testid=staff-state-waiting][phx-value-state=active][aria-pressed=true]"
             )

      assert render(view) =~ "click to resume"
    end
  end

  describe "task CRUD" do
    test "creates a task", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

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
      conv = insert_thread(organization_id: org.id)
      {:ok, task} = Threads.create_task(%{title: "Test task", thread_id: conv.id})

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      # Toggle task (open -> in_progress)
      view
      |> element("[phx-click=toggle_task][phx-value-id=\"#{task.id}\"]")
      |> render_click()

      updated = Threads.get_task!(task.id)
      assert updated.state == :in_progress
    end

    test "edits a task", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)

      {:ok, task} =
        Threads.create_task(%{title: "Original title", thread_id: conv.id})

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      # Click edit button
      view
      |> element("[phx-click=edit_task][phx-value-id=\"#{task.id}\"]")
      |> render_click()

      # Submit edit form
      view
      |> form("form[phx-submit=save_task]", title: "Updated title")
      |> render_submit()

      updated = Threads.get_task!(task.id)
      assert updated.title == "Updated title"
    end

    test "deletes a task", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)

      {:ok, task} =
        Threads.create_task(%{title: "Task to delete", thread_id: conv.id})

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      # Delete task
      view
      |> element("[phx-click=delete_task][phx-value-id=\"#{task.id}\"]")
      |> render_click()

      assert_raise Ecto.NoResultsError, fn -> Threads.get_task!(task.id) end
    end
  end

  describe "PubSub subscription" do
    test "updates when message_added event received", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      # Simulate a new message being added
      Threads.create_message!(%{
        thread_id: conv.id,
        source: :email,
        body: "New incoming message",
        is_internal_note: false
      })

      Phoenix.PubSub.broadcast(
        Custyard.PubSub,
        "thread:#{conv.id}",
        {:message_added, conv.id}
      )

      :timer.sleep(100)

      html = render(view)
      assert html =~ "New incoming message"
    end
  end

  describe "nil-organization threads" do
    defp insert_scoped_staff(org_id, role \\ "agent") do
      {:ok, staff} =
        %StaffAccount{}
        |> StaffAccount.changeset(%{
          tenant_id: Process.get(:factory_tenant_id),
          email: "#{role}-#{System.unique_integer([:positive])}@example.com",
          password: "password123",
          role: role,
          organization_id: org_id
        })
        |> Repo.insert()

      staff
    end

    defp conn_for_staff(staff) do
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.init_test_session(%{})
      |> put_staff_session(staff.id)
    end

    test "renders a nil-org thread without crashing", %{conn: conn} do
      conv =
        insert_thread(
          organization_id: nil,
          source: :disambiguation,
          subject: "Anonymous request"
        )

      insert_message(thread_id: conv.id, body: "Hello from an unlinked prospect")

      {:ok, _view, html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert html =~ "Anonymous request"
      assert html =~ "Hello from an unlinked prospect"
      assert html =~ "Unlinked prospect"
      # No org link, no tier badge without an organization
      refute html =~ "staff-sidebar-org-link"
      refute html =~ "staff-tier-badge"
    end

    test "header shows the source badge", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id, source: :portal)

      {:ok, _view, html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert html =~ ~s(data-testid="source-badge-portal")
      assert html =~ "Portal"
    end

    test "org-scoped staff can open a nil-org thread" do
      org = insert_organization()
      staff = insert_scoped_staff(org.id)

      conv =
        insert_thread(
          organization_id: nil,
          source: :disambiguation,
          subject: "Unlinked but visible"
        )

      conn = conn_for_staff(staff)

      {:ok, _view, html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert html =~ "Unlinked but visible"
      assert html =~ "Unlinked prospect"
    end

    test "org-scoped staff still cannot open another org's thread" do
      org = insert_organization()
      other_org = insert_organization(tenant_id: insert_tenant().id)
      staff = insert_scoped_staff(org.id)

      conv = insert_thread(organization_id: other_org.id, subject: "Foreign thread")

      conn = conn_for_staff(staff)

      assert {:error, {:redirect, %{to: "/app", flash: flash}}} =
               live(conn, ~p"/app/threads/#{conv.id}")

      assert flash["error"] =~ "Thread not found"
    end

    test "linking an unassigned customer within the tenant preserves staff access" do
      own = insert_organization()
      customer = insert_organization()
      contact = insert_contact(organization_id: customer.id, email: "known@customer.example")
      staff = insert_scoped_staff(own.id, "admin")
      conv = insert_thread(organization_id: nil, source: :public_intake, state: :active)
      insert_prospect(thread_id: conv.id)
      {:ok, view, _} = live(conn_for_staff(staff), ~p"/app/threads/#{conv.id}")
      assert {:ok, linked} = Custyard.Intake.capture_email(conv, contact.email)
      assert linked.organization_id == customer.id
      assert render(view) =~ "known@customer.example"
      assert Process.alive?(view.pid)
    end

    test "super_admin can open a nil-org thread", %{conn: conn} do
      # Default setup staff is super_admin
      conv = insert_thread(organization_id: nil, source: :disambiguation)

      {:ok, _view, html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert html =~ conv.subject
    end

    test "reply on a nil-org thread records the message without crashing", %{conn: conn} do
      conv = insert_thread(organization_id: nil, source: :disambiguation)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      view
      |> form("form[phx-submit=send_reply]", body: "Reply to unlinked prospect")
      |> render_submit()

      [message] = Threads.list_public_messages(conv.id)
      assert message.body == "Reply to unlinked prospect"
      assert message.source == :staff
    end
  end

  describe "convert prospect" do
    test "super_admin converts an unlinked public-intake prospect into a new organization", %{
      conn: conn
    } do
      conv = insert_thread(organization_id: nil, source: :public_intake)

      insert_prospect(
        thread_id: conv.id,
        email: "buyer@acme.com",
        email_captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

      {:ok, view, html} = live(conn, ~p"/app/threads/#{conv.id}")
      assert html =~ "staff-convert-prospect-btn"

      html =
        view
        |> element("[data-testid=staff-convert-prospect-btn]")
        |> render_click()

      # Prefilled from the prospect's captured email domain.
      assert html =~ ~s(value="acme.com")

      view
      |> form("[data-testid=staff-convert-form]", name: "Acme Corp", domain: "acme.com")
      |> render_submit()

      converted =
        Custyard.Repo.get!(Custyard.Thread, conv.id) |> Repo.preload(:organization)

      assert converted.organization.name == "Acme Corp"
      assert converted.source == :public_intake
    end

    test "the convert button is hidden for a thread already linked to an organization", %{
      conn: conn
    } do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id, source: :public_intake)

      {:ok, _view, html} = live(conn, ~p"/app/threads/#{conv.id}")

      refute html =~ "staff-convert-prospect-btn"
    end

    test "agents do not see the convert button on a nil-org prospect" do
      org = insert_organization()
      staff = insert_scoped_staff(org.id, "agent")
      conv = insert_thread(organization_id: nil, source: :public_intake)

      conn = conn_for_staff(staff)
      {:ok, _view, html} = live(conn, ~p"/app/threads/#{conv.id}")

      refute html =~ "staff-convert-prospect-btn"
    end

    test "a direct convert_prospect event from an agent is refused" do
      org = insert_organization()
      staff = insert_scoped_staff(org.id, "agent")
      conv = insert_thread(organization_id: nil, source: :public_intake)

      conn = conn_for_staff(staff)
      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      html = render_click(view, "convert_prospect", %{"name" => "Sneaky Corp"})

      assert html =~ "Only tenant administrators can convert prospects"
      assert Custyard.Repo.get!(Custyard.Thread, conv.id).organization_id == nil
    end
  end

  describe "stale task rows" do
    test "acting on a deleted task shows a notice instead of crashing", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)
      {:ok, task} = Threads.create_task(%{title: "Gone soon", thread_id: conv.id})

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      # Deleted from another session: nothing tells this view
      {:ok, _} = Threads.delete_task(task)

      html = render_click(view, "toggle_task", %{"id" => "#{task.id}"})
      assert html =~ "no longer exists"
      assert Process.alive?(view.pid)

      html = render_click(view, "delete_task", %{"id" => "#{task.id}"})
      assert html =~ "no longer exists"
      assert Process.alive?(view.pid)
    end

    test "a task of another thread cannot be edited through this view", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)
      other = insert_thread(organization_id: org.id)
      {:ok, task} = Threads.create_task(%{title: "Elsewhere", thread_id: other.id})

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      html = render_click(view, "toggle_task", %{"id" => "#{task.id}"})
      assert html =~ "no longer exists"
      assert Threads.get_task!(task.id).state == :open
    end
  end

  describe "inbound channel surfaces" do
    test "header shows the channel badge when the thread arrived on a channel", %{
      conn: conn
    } do
      org = insert_organization()

      channel =
        insert_inbound_channel(
          organization_id: org.id,
          public_address: "support@acme.example.com",
          state: :active
        )

      conv = insert_thread(organization_id: org.id, inbound_channel_id: channel.id)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert view |> element("[data-testid=thread-channel]") |> render() =~
               "support@acme.example.com"

      refute render(view) =~ channel.ingress_token
    end

    test "no channel badge without a channel", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      refute has_element?(view, "[data-testid=thread-channel]")
      refute has_element?(view, "[data-testid=thread-suspect-badge]")
    end

    test "suspect badge can be dismissed", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)
      {:ok, _} = Threads.set_suspect(conv, true)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert has_element?(view, "[data-testid=thread-suspect-badge]")
      view |> element("[data-testid=dismiss-suspect]") |> render_click()

      refute has_element?(view, "[data-testid=thread-suspect-badge]")
      refute Custyard.Repo.get!(Custyard.Thread, conv.id).suspect
    end

    test "email messages carry a collapsed details line with envelope data", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)

      msg =
        insert_message(
          thread_id: conv.id,
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

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      details =
        view
        |> element("[data-testid=staff-message-#{msg.id}] [data-testid=message-details]")
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
      conv = insert_thread(organization_id: org.id)

      insert_message(
        thread_id: conv.id,
        source: :email,
        sender_email: "alice@customer.example",
        reply_to: "Alice@Customer.example",
        authentication: %{"dkim" => "fail", "dkim_domain" => "customer.example"}
      )

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      refute has_element?(view, "[data-testid=message-reply-to]")
      refute has_element?(view, "[data-testid=message-cc]")

      badge = view |> element("[data-testid=message-auth-badge]") |> render()
      assert badge =~ "DKIM fail"
      assert badge =~ ~s(data-auth-result="fail")
    end

    test "authentication badge variants: unauthenticated and no data", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)

      none =
        insert_message(
          thread_id: conv.id,
          source: :email,
          authentication: %{"spf" => "pass"}
        )

      missing = insert_message(thread_id: conv.id, source: :email, authentication: nil)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert view
             |> element("[data-testid=staff-message-#{none.id}] [data-testid=message-auth-badge]")
             |> render() =~ "unauthenticated"

      assert view
             |> element(
               "[data-testid=staff-message-#{missing.id}] [data-testid=message-auth-badge]"
             )
             |> render() =~ "no auth data"
    end

    test "staff and portal messages have no details line", %{conn: conn} do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)
      insert_message(thread_id: conv.id, source: :staff, body: "Reply")
      insert_message(thread_id: conv.id, source: :portal, body: "Portal")

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      refute has_element?(view, "[data-testid=message-details]")
      refute has_element?(view, "[data-testid=message-auth-badge]")
    end

    test "auto-responses render as muted system messages, suspect messages get a tag", %{
      conn: conn
    } do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)

      auto =
        insert_message(
          thread_id: conv.id,
          source: :email,
          triage_class: :auto_response,
          body: "I am out of the office"
        )

      suspect =
        insert_message(
          thread_id: conv.id,
          source: :email,
          triage_class: :suspect,
          body: "Urgent wire transfer"
        )

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      auto_html = view |> element("[data-testid=staff-message-#{auto.id}]") |> render()
      assert auto_html =~ ~s(data-testid="message-system-tag")
      assert auto_html =~ "auto-reply"
      assert auto_html =~ "italic"
      assert has_element?(view, "[data-testid=staff-message-delete-#{auto.id}]")

      suspect_html = view |> element("[data-testid=staff-message-#{suspect.id}]") |> render()
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

      conv = insert_thread(organization_id: org.id, inbound_channel_id: channel.id)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      identity = view |> element("[data-testid=composer-from-identity]") |> render()
      assert identity =~ "Replies go out as"
      assert identity =~ "Acme Support"
      assert identity =~ "support@acme.example.com"
      assert identity =~ ~s(data-identity-source="channel")
    end

    test "composer requires a tenant sender instead of showing the installation sender", %{
      conn: conn,
      sending_channel: channel
    } do
      Repo.update!(Ecto.Changeset.change(channel, state: :paused))
      conv = insert_thread(source: :public_intake)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      identity = view |> element("[data-testid=composer-from-identity]") |> render()
      assert identity =~ ~s(data-identity-source="platform")

      assert identity =~ "Choose a tenant sending address"

      refute identity =~
               Application.get_env(:custyard, :email_from_address, "support@custyard.local")
    end
  end

  describe "conversation layout" do
    setup do
      org = insert_organization(name: "Acme Corp")
      contact = insert_contact(organization_id: org.id, name: "Alice", email: "alice@acme.com")
      conv = insert_thread(organization_id: org.id, contact_id: contact.id, subject: "Invoice")
      %{org: org, contact: contact, conv: conv}
    end

    test "the subject is the page title with customer and contact beneath it", %{
      conn: conn,
      conv: conv,
      org: org
    } do
      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert has_element?(view, "h1[data-testid=staff-thread-subject]", "Invoice")
      refute has_element?(view, "h1 a")

      assert has_element?(
               view,
               "header [data-testid=staff-thread-customer-link][href='/app/customers/#{org.public_id}']",
               "Acme Corp"
             )

      assert has_element?(
               view,
               "header [data-testid=staff-thread-contact]",
               "Alice <alice@acme.com>"
             )

      assert has_element?(
               view,
               "header [data-testid=staff-thread-back][href='/app?at=#{conv.id}']"
             )

      assert has_element?(view, "header [data-testid=staff-state-badge-active]")
    end

    test "a contact that only repeats the customer is not printed twice", %{conn: conn} do
      org = insert_organization(name: "solo@example.com")
      contact = insert_contact(organization_id: org.id, name: nil, email: "solo@example.com")
      conv = insert_thread(organization_id: org.id, contact_id: contact.id)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      refute has_element?(view, "[data-testid=staff-thread-contact]")

      sidebar = view |> element("[data-testid=staff-sidebar-contact]") |> render()
      assert length(String.split(sidebar, "solo@example.com")) == 2
    end

    test "messages carry sender, channel and a time with the absolute timestamp on hover", %{
      conn: conn,
      conv: conv
    } do
      message = insert_message(thread_id: conv.id, body: "Hello", sender_email: "alice@acme.com")

      Repo.update_all(
        from(m in Custyard.Message, where: m.id == ^message.id),
        set: [inserted_at: ~U[2026-03-04 15:06:00Z]]
      )

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")
      entry = "[data-testid=staff-message-#{message.id}]"

      assert has_element?(view, "#{entry} [data-testid=staff-message-sender]", "alice@acme.com")
      assert has_element?(view, entry, "via email")

      assert has_element?(
               view,
               "#{entry} time[data-testid=staff-message-time][datetime='2026-03-04T15:06:00Z'][title='Mar 4, 2026 15:06 UTC']"
             )
    end

    test "a plain-text body renders without stray leading whitespace", %{conn: conn, conv: conv} do
      message = insert_message(thread_id: conv.id, body: "First line\n  indented line")

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert view
             |> element(
               "[data-testid=staff-message-#{message.id}] [data-testid=staff-message-body]"
             )
             |> render() =~ ">First line\n  indented line</div>"
    end

    test "customer messages, staff replies and internal notes are marked apart", %{
      conn: conn,
      conv: conv
    } do
      customer = insert_message(thread_id: conv.id, body: "Question")
      reply = insert_message(thread_id: conv.id, source: :staff, body: "Answer")

      note =
        insert_message(thread_id: conv.id, source: :staff, is_internal_note: true, body: "Memo")

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert has_element?(
               view,
               "[data-testid=staff-message-#{customer.id}] [data-testid=staff-message-email]"
             )

      assert has_element?(
               view,
               "[data-testid=staff-message-#{reply.id}] [data-testid=staff-message-staff]"
             )

      assert has_element?(
               view,
               "[data-testid=staff-message-#{note.id}] [data-testid=staff-message-internal] [data-testid=staff-message-internal-badge]",
               "internal note"
             )

      refute has_element?(
               view,
               "[data-testid=staff-message-#{reply.id}] [data-testid=staff-message-internal-badge]"
             )
    end

    test "the sidebar starts with the state actions and keeps the score collapsed", %{
      conn: conn,
      conv: conv
    } do
      {:ok, view, html} = live(conn, ~p"/app/threads/#{conv.id}")

      {actions, _} = :binary.match(html, ~s(data-testid="staff-state-actions"))
      {customer, _} = :binary.match(html, ~s(data-testid="staff-sidebar-org"))
      assert actions < customer

      assert has_element?(view, "details[data-testid=staff-sidebar-score] summary", "score")
      refute has_element?(view, "details[data-testid=staff-sidebar-score][open]")

      assert has_element?(
               view,
               "details[data-testid=staff-sidebar-score] [data-testid=staff-score-breakdown]"
             )

      # The contact's address is printed once.
      sidebar = view |> element("[data-testid=staff-thread-sidebar]") |> render()
      assert length(String.split(sidebar, "alice@acme.com")) == 2
    end

    test "other open conversations show their subject, state and age", %{
      conn: conn,
      conv: conv,
      org: org
    } do
      other =
        insert_thread(
          organization_id: org.id,
          state: :waiting,
          subject: "Feedback on Nov 10, 2026 via eu.example.com (custom)"
        )

      Repo.update_all(
        from(t in Custyard.Thread, where: t.id == ^other.id),
        set: [
          inserted_at: DateTime.add(DateTime.utc_now(), -3, :day) |> DateTime.truncate(:second)
        ]
      )

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")
      entry = "a[data-testid=staff-other-conv-#{other.id}][href='/app/threads/#{other.id}']"

      assert has_element?(view, entry, "Feedback on Nov 10, 2026 via eu.example.com (custom)")
      assert has_element?(view, "#{entry} [data-testid=staff-state-badge-waiting]", "waiting")
      assert has_element?(view, "#{entry} time", "opened 3d ago")
    end

    test "another open conversation under a minute old was opened just now", %{
      conn: conn,
      conv: conv,
      org: org
    } do
      other = insert_thread(organization_id: org.id, state: :waiting)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")
      entry = "a[data-testid=staff-other-conv-#{other.id}]"

      assert has_element?(view, "#{entry} time", "opened just now")
      refute has_element?(view, "#{entry} time", "ago")
    end
  end

  describe "collapsed composer" do
    setup do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, email: "alice@customer.example")
      conv = insert_thread(organization_id: org.id, contact_id: contact.id)

      insert_message(
        thread_id: conv.id,
        source: :email,
        sender_email: "alice@customer.example",
        cc_addresses: ["boss@customer.example"],
        triage_class: :customer
      )

      %{conv: conv}
    end

    test "From, To and CC start as one summary line with the fields still in the form", %{
      conn: conn,
      conv: conv,
      sending_channel: channel
    } do
      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")
      recipients = "#staff-reply-form details[data-testid=composer-recipients]"

      assert has_element?(view, recipients)
      refute has_element?(view, "#{recipients}[open]")

      assert has_element?(
               view,
               "#{recipients} summary [data-testid=staff-reply-to]",
               "alice@customer.example"
             )

      assert has_element?(
               view,
               "#{recipients} summary [data-testid=composer-cc-summary]",
               "boss@customer.example"
             )

      assert has_element?(
               view,
               "#{recipients} summary [data-testid=composer-from-identity]",
               channel.public_address
             )

      # Collapsed is not removed: the fields are submitted with the reply.
      assert has_element?(view, "#{recipients} select#staff-reply-from[name=reply_channel_id]")
      assert has_element?(view, "#{recipients} input[name=cc][value='boss@customer.example']")
      refute has_element?(view, "#{recipients} summary input")
      refute has_element?(view, "#{recipients} summary select")

      assert has_element?(
               view,
               "#staff-reply-form textarea#staff-reply-textarea[rows='3'][phx-hook=ComposerInput]"
             )
    end

    test "the summary follows edits to the CC list", %{conn: conn, conv: conv} do
      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      view |> form("#staff-reply-form", body: "Hi", cc: "") |> render_change()
      assert has_element?(view, "[data-testid=composer-cc-summary]", "nobody else")

      view |> form("#staff-reply-form", body: "Hi", cc: "ops@customer.example") |> render_change()
      assert has_element?(view, "[data-testid=composer-cc-summary]", "ops@customer.example")
    end

    test "a reply sent while collapsed still goes to the summarised recipients", %{
      conn: conn,
      conv: conv,
      sending_channel: channel
    } do
      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      view |> form("#staff-reply-form", body: "Sent while collapsed") |> render_submit()

      [reply] = Threads.list_public_messages(conv.id) |> Enum.filter(&(&1.source == :staff))
      assert reply.cc_addresses == ["boss@customer.example"]
      assert reply.inbound_channel_id == channel.id
    end

    test "opens when there is no sending address to reply from", %{
      conn: conn,
      conv: conv,
      sending_channel: channel
    } do
      Repo.update!(Ecto.Changeset.change(channel, state: :paused))

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert has_element?(view, "details[data-testid=composer-recipients][open]")

      assert has_element?(
               view,
               "[data-testid=composer-from-identity]",
               "Choose a tenant sending address"
             )
    end

    test "opens when a draft was restored so the recipients get re-read", %{
      conn: conn,
      conv: conv
    } do
      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      view
      |> form("#staff-reply-form", body: "Unsent", cc: "late@customer.example")
      |> render_change()

      {:ok, restored, _html} = live(conn, ~p"/app/threads/#{conv.id}")

      assert has_element?(restored, "details[data-testid=composer-recipients][open]")
      assert has_element?(restored, "[data-testid=composer-cc-summary]", "late@customer.example")
    end

    test "the note composer has no recipients and is marked as private", %{conn: conn, conv: conv} do
      {:ok, view, _html} = live(conn, ~p"/app/threads/#{conv.id}")
      assert has_element?(view, "[data-testid=staff-composer][data-composer-mode=reply]")

      view |> element("[data-testid=composer-mode-note]") |> render_click()

      assert has_element?(view, "[data-testid=staff-composer][data-composer-mode=note]")
      refute has_element?(view, "[data-testid=composer-recipients]")
      assert has_element?(view, "#staff-note-form textarea[rows='3'][phx-hook=ComposerInput]")
      assert has_element?(view, "[data-testid=staff-note-submit]", "Save internal note")
      refute has_element?(view, "[data-testid=staff-reply-submit]")
    end
  end

  describe "stepping through the queue" do
    setup do
      org = insert_organization()

      # Queue order is score first, so these list as a, b, c.
      [a, b, c] =
        for {subject, score} <- [{"Thread A", 90}, {"Thread B", 60}, {"Thread C", 30}] do
          thread =
            insert_thread(
              organization_id: org.id,
              state: :active,
              subject: subject,
              cached_score: score
            )

          insert_message(thread_id: thread.id, body: "Question about #{subject}")
          thread
        end

      %{org: org, a: a, b: b, c: c}
    end

    test "previous and next follow the queue order", %{conn: conn, a: a, b: b, c: c} do
      {:ok, view, _html} = live(conn, ~p"/app/threads/#{b.id}?pos=1")
      nav = "header nav[data-testid=staff-thread-queue-nav]"

      assert has_element?(view, "#{nav} [data-testid=staff-thread-queue-position]", "2 of 3")

      assert has_element?(
               view,
               "#{nav} a[data-testid=staff-thread-prev][data-shortcut=k][href='/app/threads/#{a.id}?pos=0&before=#{b.id}%2C#{c.id}']",
               "Previous"
             )

      assert has_element?(
               view,
               "#{nav} a[data-testid=staff-thread-next][data-shortcut=j][href='/app/threads/#{c.id}?pos=2&after=#{b.id}%2C#{a.id}']",
               "Next"
             )

      assert has_element?(
               view,
               "a[data-testid=staff-thread-back][data-shortcut=u][href='/app?at=#{b.id}'][title='Back to the queue (u)']"
             )

      assert has_element?(view, "header#thread-header[phx-hook=Shortcuts]")
    end

    test "the ends of the queue have no link in that direction", %{conn: conn, a: a, b: b, c: c} do
      {:ok, first, _html} = live(conn, ~p"/app/threads/#{a.id}")
      refute has_element?(first, "[data-testid=staff-thread-prev]")
      assert has_element?(first, "[data-testid=staff-thread-prev-none][aria-disabled=true]")

      assert has_element?(
               first,
               "a[data-testid=staff-thread-next][href='/app/threads/#{b.id}?pos=1&after=#{a.id}&before=#{c.id}']"
             )

      {:ok, last, _html} = live(conn, ~p"/app/threads/#{c.id}")

      assert has_element?(
               last,
               "a[data-testid=staff-thread-prev][href='/app/threads/#{b.id}?pos=1&after=#{a.id}&before=#{c.id}']"
             )

      assert has_element?(last, "[data-testid=staff-thread-next-none][aria-disabled=true]")
    end

    test "follows the filter and label the conversation was opened from", %{
      conn: conn,
      staff: staff,
      a: a,
      b: b,
      c: c
    } do
      # b has been answered, so the needs-reply queue is a, c.
      insert_message(thread_id: b.id, source: :staff, body: "Answered")

      scope = Custyard.Scope.for_staff(staff, Custyard.Tenants.get_tenant!(staff.tenant_id))
      {:ok, label} = Custyard.Labels.create_and_assign(scope, a, "Billing")
      {:ok, _} = Custyard.Labels.assign(scope, c, label.id)

      # Needs reply is the default queue, so its links do not name it.
      {:ok, view, _html} =
        live(conn, ~p"/app/threads/#{a.id}?filter=needs_reply&label=#{label.id}&pos=0")

      assert has_element?(view, "[data-testid=staff-thread-queue-position]", "needs reply")
      assert has_element?(view, "[data-testid=staff-thread-queue-position]", "1 of 2")

      assert has_element?(
               view,
               "a[data-testid=staff-thread-next][href='/app/threads/#{c.id}?label=#{label.id}&pos=1&after=#{a.id}']"
             )

      assert has_element?(
               view,
               "a[data-testid=staff-thread-back][href='/app?label=#{label.id}&at=#{a.id}']"
             )

      # Any other filter is named, on the way on and on the way back.
      {:ok, active, _html} =
        live(conn, ~p"/app/threads/#{a.id}?filter=active&label=#{label.id}&pos=0")

      assert has_element?(active, "[data-testid=staff-thread-queue-position]", "1 of 2 in active")

      assert has_element?(
               active,
               "a[data-testid=staff-thread-next][href='/app/threads/#{c.id}?filter=active&label=#{label.id}&pos=1&after=#{a.id}']"
             )

      assert has_element?(
               active,
               "a[data-testid=staff-thread-back][href='/app?filter=active&label=#{label.id}&at=#{a.id}']"
             )
    end

    test "a link without a filter steps through needs reply; all is named", %{
      conn: conn,
      a: a,
      b: b,
      c: c
    } do
      # b has been answered: it is in the whole queue but needs no reply.
      insert_message(thread_id: b.id, source: :staff, body: "Answered")

      {:ok, default, _html} = live(conn, ~p"/app/threads/#{a.id}?pos=0")

      assert has_element?(
               default,
               "[data-testid=staff-thread-queue-position]",
               "1 of 2 in needs reply"
             )

      assert has_element?(
               default,
               "a[data-testid=staff-thread-next][href='/app/threads/#{c.id}?pos=1&after=#{a.id}']"
             )

      assert has_element?(default, "a[data-testid=staff-thread-back][href='/app?at=#{a.id}']")

      {:ok, all, _html} = live(conn, ~p"/app/threads/#{a.id}?filter=all&pos=0")

      assert has_element?(all, "[data-testid=staff-thread-queue-position]", "1 of 3")
      refute has_element?(all, "[data-testid=staff-thread-queue-position]", "needs reply")

      assert has_element?(
               all,
               "a[data-testid=staff-thread-next][href='/app/threads/#{b.id}?filter=all&pos=1&after=#{a.id}&before=#{c.id}']"
             )

      assert has_element?(
               all,
               "a[data-testid=staff-thread-back][href='/app?filter=all&at=#{a.id}']"
             )
    end

    test "previous and next follow a reversed list", %{conn: conn, a: a, b: b, c: c} do
      # The list read c, b, a, and b was opened from its second row.
      {:ok, view, _html} =
        live(conn, ~p"/app/threads/#{b.id}?reverse=1&pos=1&after=#{c.id}&before=#{a.id}")

      assert has_element?(view, "[data-testid=staff-thread-queue-position]", "2 of 3")

      assert has_element?(
               view,
               "a[data-testid=staff-thread-prev][href='/app/threads/#{c.id}?reverse=1&pos=0&before=#{b.id}%2C#{a.id}']"
             )

      assert has_element?(
               view,
               "a[data-testid=staff-thread-next][href='/app/threads/#{a.id}?reverse=1&pos=2&after=#{b.id}%2C#{c.id}']"
             )

      assert has_element?(
               view,
               "a[data-testid=staff-thread-back][href='/app?reverse=1&at=#{b.id}']"
             )

      # Stepping on keeps the order.
      {:ok, next, _html} =
        view
        |> element("a[data-testid=staff-thread-next]")
        |> render_click()
        |> follow_redirect(conn)

      assert has_element?(next, "[data-testid=staff-thread-subject]", "Thread A")
      assert has_element?(next, "[data-testid=staff-thread-queue-position]", "3 of 3")
      assert has_element?(next, "[data-testid=staff-thread-next-none]")

      assert has_element?(
               next,
               "a[data-testid=staff-thread-prev][href^='/app/threads/#{b.id}?reverse=1&']"
             )

      # With a filter, the filter comes first.
      {:ok, all, _html} = live(conn, ~p"/app/threads/#{c.id}?filter=all&reverse=1&pos=0")

      assert has_element?(
               all,
               "a[data-testid=staff-thread-next][href='/app/threads/#{b.id}?filter=all&reverse=1&pos=1&after=#{c.id}&before=#{a.id}']"
             )

      assert has_element?(
               all,
               "a[data-testid=staff-thread-back][href='/app?filter=all&reverse=1&at=#{c.id}']"
             )

      # Anything but reverse=1 is the default order.
      {:ok, forward, _html} = live(conn, ~p"/app/threads/#{b.id}?reverse=true&pos=1")

      assert has_element?(
               forward,
               "a[data-testid=staff-thread-prev][href^='/app/threads/#{a.id}?pos=0']"
             )
    end

    test "keeps the place in the queue after a reply takes the conversation out of it", %{
      conn: conn,
      a: a,
      b: b,
      c: c
    } do
      {:ok, view, _html} = live(conn, ~p"/app/threads/#{b.id}?filter=needs_reply&pos=1")
      assert has_element?(view, "[data-testid=staff-thread-queue-position]", "2 of 3")

      view |> form("#staff-reply-form", body: "Here is the answer") |> render_submit()

      # b no longer needs a reply. c moved up into its place, a is still before it.
      assert has_element?(view, "[data-testid=staff-thread-queue-position]", "2 of 2")

      assert has_element?(
               view,
               "a[data-testid=staff-thread-prev][href='/app/threads/#{a.id}?pos=0&before=#{c.id}']"
             )

      assert has_element?(
               view,
               "a[data-testid=staff-thread-next][href='/app/threads/#{c.id}?pos=1&after=#{a.id}']"
             )
    end

    test "opening a new conversation from the new filter still offers the one after it", %{
      conn: conn,
      org: org
    } do
      [first, second, third] =
        for score <- [80, 70, 65] do
          insert_thread(organization_id: org.id, state: :new, cached_score: score)
        end

      # Opening `second` makes it active, so it is gone from the "new" queue
      # by the time the page renders; the row's position stands in for it.
      {:ok, view, _html} = live(conn, ~p"/app/threads/#{second.id}?filter=new&pos=1")
      assert Repo.get!(Custyard.Thread, second.id).state == :active

      assert has_element?(
               view,
               "a[data-testid=staff-thread-prev][href='/app/threads/#{first.id}?filter=new&pos=0&before=#{third.id}']"
             )

      assert has_element?(
               view,
               "a[data-testid=staff-thread-next][href='/app/threads/#{third.id}?filter=new&pos=1&after=#{first.id}']"
             )
    end

    test "opening a conversation that sinks in the queue keeps the place it was opened at", %{
      conn: conn,
      org: org,
      a: a
    } do
      # A new thread ranked just under A. Opening it makes it active and
      # resets its idle time, so its recalculated score drops below B and C.
      fresh = insert_thread(organization_id: org.id, state: :new, cached_score: 85)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{fresh.id}?pos=1")

      order = Threads.queue_ids(Custyard.Factory.staff_scope(fresh.tenant_id))
      assert List.last(order) == fresh.id, "the opened thread sank to the end of the queue"
      [^a, after_fresh, third | _] = Enum.map(order, &Repo.get!(Custyard.Thread, &1))

      assert has_element?(view, "[data-testid=staff-thread-queue-position]", "2 of 4")

      assert has_element?(
               view,
               "a[data-testid=staff-thread-prev][href='/app/threads/#{a.id}?pos=0&before=#{after_fresh.id}%2C#{third.id}%2C#{fresh.id}']"
             )

      assert has_element?(
               view,
               "a[data-testid=staff-thread-next][href='/app/threads/#{after_fresh.id}?pos=1&after=#{a.id}&before=#{third.id}%2C#{fresh.id}']"
             )
    end

    test "Next leads on from the conversation just read after the queue changed above it", %{
      conn: conn,
      org: org,
      a: a,
      b: b,
      c: c
    } do
      [d, e] =
        for score <- [20, 10] do
          insert_thread(organization_id: org.id, state: :active, cached_score: score)
        end

      follow_next = fn view ->
        {:ok, next, _html} =
          view
          |> element("a[data-testid=staff-thread-next]")
          |> render_click()
          |> follow_redirect(conn)

        assert has_element?(next, "[data-testid=staff-thread-subject]", "Thread C")
        next
      end

      # A colleague resolves the conversation above while B is being read.
      # B's page is not told, so its Next link is the one rendered before.
      {:ok, reading_b, _html} = live(conn, ~p"/app/threads/#{b.id}?pos=1")
      Repo.update_all(from(t in Custyard.Thread, where: t.id == ^a.id), set: [state: :resolved])
      next = follow_next.(reading_b)

      assert has_element?(next, "[data-testid=staff-thread-queue-position]", "2 of 4")

      assert has_element?(
               next,
               "a[data-testid=staff-thread-prev][href='/app/threads/#{b.id}?pos=0&before=#{c.id}%2C#{d.id}%2C#{e.id}']"
             )

      assert has_element?(
               next,
               "a[data-testid=staff-thread-next][href='/app/threads/#{d.id}?pos=2&after=#{c.id}%2C#{b.id}&before=#{e.id}']"
             )

      # Or a new conversation arrives on top of the queue.
      Repo.update_all(from(t in Custyard.Thread, where: t.id == ^a.id), set: [state: :active])
      {:ok, reading_b, _html} = live(conn, ~p"/app/threads/#{b.id}?pos=1")
      n = insert_thread(organization_id: org.id, state: :new, cached_score: 95)
      next = follow_next.(reading_b)

      assert has_element?(next, "[data-testid=staff-thread-queue-position]", "4 of 6")

      assert has_element?(
               next,
               "a[data-testid=staff-thread-prev][href='/app/threads/#{b.id}?pos=2&after=#{a.id}%2C#{n.id}&before=#{c.id}%2C#{d.id}%2C#{e.id}']"
             )

      assert has_element?(
               next,
               "a[data-testid=staff-thread-next][href='/app/threads/#{d.id}?pos=4&after=#{c.id}%2C#{b.id}%2C#{a.id}&before=#{e.id}']"
             )
    end

    test "a reload starts from the neighbours last shown, not from those in the link", %{
      conn: conn,
      org: org,
      a: a,
      b: b,
      c: c
    } do
      [d, e] =
        for score <- [20, 10] do
          insert_thread(organization_id: org.id, state: :active, cached_score: score)
        end

      resolve = fn thread ->
        Repo.update_all(
          from(t in Custyard.Thread, where: t.id == ^thread.id),
          set: [state: :resolved]
        )
      end

      {:ok, view, _html} =
        live(conn, ~p"/app/threads/#{c.id}?pos=2&after=#{b.id}&before=#{d.id}")

      assert has_element?(view, "[data-testid=staff-thread-queue-position]", "3 of 5")

      # The conversation before it leaves the queue: the one after still places it.
      resolve.(b)
      send(view.pid, {:thread_updated, c.id})

      assert has_element?(view, "[data-testid=staff-thread-queue-position]", "2 of 4")
      assert has_element?(view, "a[data-testid=staff-thread-prev][href^='/app/threads/#{a.id}?']")
      assert has_element?(view, "a[data-testid=staff-thread-next][href^='/app/threads/#{d.id}?']")

      # Then the one after it leaves too. Both ids of the link are gone by now,
      # but A was shown as the previous one on the last reload.
      resolve.(d)
      send(view.pid, {:thread_updated, c.id})

      assert has_element?(view, "[data-testid=staff-thread-queue-position]", "2 of 3")
      assert has_element?(view, "a[data-testid=staff-thread-prev][href^='/app/threads/#{a.id}?']")
      assert has_element?(view, "a[data-testid=staff-thread-next][href^='/app/threads/#{e.id}?']")
    end

    test "shows no queue controls for a conversation that is not in the queue", %{
      conn: conn,
      org: org
    } do
      resolved = insert_thread(organization_id: org.id, state: :resolved)

      {:ok, view, _html} = live(conn, ~p"/app/threads/#{resolved.id}")

      refute has_element?(view, "[data-testid=staff-thread-queue-nav]")
      assert has_element?(view, "a[data-testid=staff-thread-back][href='/app?at=#{resolved.id}']")
    end

    test "a reload is not led astray by a neighbour that moved", %{
      conn: conn,
      org: org,
      a: a,
      b: b,
      c: c
    } do
      [d, _e] =
        for score <- [20, 10] do
          insert_thread(organization_id: org.id, state: :active, cached_score: score)
        end

      rescore = fn thread, score ->
        Repo.update_all(
          from(t in Custyard.Thread, where: t.id == ^thread.id),
          set: [cached_score: score]
        )
      end

      placed_between_a_and_d = fn view ->
        has_element?(view, "a[data-testid=staff-thread-prev][href^='/app/threads/#{a.id}?']") and
          has_element?(view, "a[data-testid=staff-thread-next][href^='/app/threads/#{d.id}?']")
      end

      {:ok, view, _html} =
        live(conn, ~p"/app/threads/#{c.id}?pos=2&after=#{b.id}&before=#{d.id}")

      assert has_element?(view, "[data-testid=staff-thread-queue-position]", "3 of 5")

      # B, listed just before, sinks to the end: a colleague answered it.
      rescore.(b, 5)
      send(view.pid, {:thread_updated, c.id})

      assert has_element?(view, "[data-testid=staff-thread-queue-position]", "2 of 5")
      assert placed_between_a_and_d.(view)

      # Then B rises to the top: its customer wrote again.
      rescore.(b, 95)
      send(view.pid, {:thread_updated, c.id})

      assert has_element?(view, "[data-testid=staff-thread-queue-position]", "3 of 5")
      assert placed_between_a_and_d.(view)
    end

    # Two people working the queue from the top: the conversation a link
    # names as the one after its target is the one a colleague takes next.
    test "a link still places its target after a colleague opened the next conversation", %{
      conn: conn,
      org: org,
      a: a
    } do
      [n1, n2, n3, n4] =
        for score <- [99, 98, 97, 96] do
          insert_thread(organization_id: org.id, state: :new, cached_score: score)
        end

      {:ok, reading, _html} = live(conn, ~p"/app/threads/#{n1.id}?pos=0&before=#{n2.id}")
      next_path = "/app/threads/#{n2.id}?pos=0&before=#{n3.id}%2C#{n4.id}%2C#{a.id}"
      assert has_element?(reading, "a[data-testid=staff-thread-next][href='#{next_path}']")

      # Opening activates it, and it sinks to the end.
      {:ok, _colleague, _html} = live(conn, ~p"/app/threads/#{n3.id}")
      scope = Custyard.Factory.staff_scope(n3.tenant_id)
      assert List.last(Threads.queue_ids(scope)) == n3.id

      first_with_n4_next = fn view ->
        has_element?(view, "[data-testid=staff-thread-queue-position]", "1 of 7") and
          has_element?(view, "[data-testid=staff-thread-prev-none]") and
          has_element?(view, "a[data-testid=staff-thread-next][href^='/app/threads/#{n4.id}?']")
      end

      # Followed the way the browser does, without a page load.
      {:ok, next, _html} = live_redirect(reading, to: next_path)
      assert first_with_n4_next.(next)

      # And as a page load, where the conversation has already sunk by the
      # time the socket connects.
      {:ok, loaded, _html} = live(conn, next_path)
      assert first_with_n4_next.(loaded)
    end

    test "a page keeps its place when a colleague opens the next conversation", %{
      conn: conn,
      org: org,
      a: a,
      b: b
    } do
      # Listed between B and C: x, then q1, q2.
      [x, q1, q2] =
        for score <- [50, 45, 40] do
          insert_thread(organization_id: org.id, state: :new, cached_score: score)
        end

      {:ok, view, _html} =
        live(conn, ~p"/app/threads/#{x.id}?pos=2&after=#{b.id}&before=#{q1.id}")

      assert has_element?(view, "[data-testid=staff-thread-queue-position]", "3 of 6")

      assert has_element?(
               view,
               "a[data-testid=staff-thread-next][href^='/app/threads/#{q1.id}?']"
             )

      # A colleague opens q1, which sinks below everything, x included.
      {:ok, _colleague, _html} = live(conn, ~p"/app/threads/#{q1.id}")
      send(view.pid, {:thread_updated, x.id})

      assert has_element?(view, "[data-testid=staff-thread-queue-position]", "3 of 6")
      assert has_element?(view, "a[data-testid=staff-thread-prev][href^='/app/threads/#{b.id}?']")

      assert has_element?(
               view,
               "a[data-testid=staff-thread-next][href^='/app/threads/#{q2.id}?']"
             )

      # The same at the top of the queue, where nothing is listed before.
      [t1, t2, t3] =
        for score <- [99, 98, 97] do
          insert_thread(organization_id: org.id, state: :new, cached_score: score)
        end

      {:ok, top, _html} = live(conn, ~p"/app/threads/#{t1.id}?pos=0&before=#{t2.id}")
      {:ok, _colleague, _html} = live(conn, ~p"/app/threads/#{t2.id}")
      send(top.pid, {:thread_updated, t1.id})

      assert has_element?(top, "[data-testid=staff-thread-prev-none]")
      assert has_element?(top, "a[data-testid=staff-thread-next][href^='/app/threads/#{t3.id}?']")
      refute has_element?(top, "a[data-testid=staff-thread-next][href^='/app/threads/#{a.id}?']")
    end

    # Two changes that hit the nearest conversation on each side of a link's
    # target: the other two on each side still place it.
    test "a link's target stays in place when both of its neighbours moved", %{
      conn: conn,
      org: org
    } do
      [n1, n2, n3, n4, n5, n6, n7, _n8] =
        for score <- 99..92//-1 do
          insert_thread(organization_id: org.id, state: :new, cached_score: score)
        end

      # From the queue page, as staff do.
      {:ok, queue, _html} = live(conn, ~p"/app")

      [row_path] =
        queue
        |> element("li#queue-row-#{n4.id} a[data-row-link]")
        |> render()
        |> Floki.parse_fragment!()
        |> Floki.attribute("href")

      {:ok, reading, _html} = live(conn, row_path)

      next_path =
        "/app/threads/#{n5.id}?pos=3&after=#{n3.id}%2C#{n2.id}%2C#{n1.id}&before=#{n6.id}%2C#{n7.id}"

      assert has_element?(reading, "a[data-testid=staff-thread-next][href^='#{next_path}']")

      # A colleague opens n3, which sinks to the end, and n6's customer
      # writes again, which raises it to the top.
      {:ok, _colleague, _html} = live(conn, ~p"/app/threads/#{n3.id}")
      Repo.update_all(from(t in Custyard.Thread, where: t.id == ^n6.id), set: [cached_score: 100])

      {:ok, next, _html} =
        reading
        |> element("a[data-testid=staff-thread-next]")
        |> render_click()
        |> follow_redirect(conn)

      assert has_element?(
               next,
               "a[data-testid=staff-thread-prev][href^='/app/threads/#{n2.id}?']"
             )

      assert has_element?(
               next,
               "a[data-testid=staff-thread-next][href^='/app/threads/#{n7.id}?']"
             )
    end

    test "two people working down the queue are each offered every conversation once", %{
      conn: conn,
      org: org
    } do
      new =
        for score <- 99..92//-1 do
          insert_thread(organization_id: org.id, state: :new, cached_score: score).id
        end

      next_id = fn view ->
        [href] =
          view
          |> element("a[data-testid=staff-thread-next]")
          |> render()
          |> Floki.parse_fragment!()
          |> Floki.attribute("href")

        {href, href |> URI.parse() |> Map.fetch!(:path) |> Path.basename() |> String.to_integer()}
      end

      {:ok, view, _html} =
        live(conn, ~p"/app/threads/#{hd(new)}?pos=0&before=#{Enum.at(new, 1)}")

      # Each round the colleague opens the conversation the reader would get
      # next, the reader's page reloads (as it does after a reply), and the
      # reader steps on.
      {_view, mine, theirs} =
        Enum.reduce(1..3, {view, [hd(new)], []}, fn _round, {view, mine, theirs} ->
          {_href, taken} = next_id.(view)
          {:ok, _colleague, _html} = live(conn, ~p"/app/threads/#{taken}")
          send(view.pid, {:thread_updated, List.last(mine)})

          {href, following} = next_id.(view)
          {:ok, view, _html} = live_redirect(view, to: href)
          {view, mine ++ [following], theirs ++ [taken]}
        end)

      [n1, n2, n3, n4, n5, n6, n7, _n8] = new
      assert mine == [n1, n3, n5, n7]
      assert theirs == [n2, n4, n6]
    end

    test "ignores unknown filters and malformed positions", %{conn: conn, a: a, b: b, c: c} do
      {:ok, view, _html} = live(conn, ~p"/app/threads/#{a.id}?filter=everything&label=x&pos=-4")

      assert has_element?(view, "[data-testid=staff-thread-queue-position]", "1 of 3")

      assert has_element?(
               view,
               "a[data-testid=staff-thread-next][href='/app/threads/#{b.id}?pos=1&after=#{a.id}&before=#{c.id}']"
             )

      assert has_element?(view, "a[data-testid=staff-thread-back][href='/app?at=#{a.id}']")
    end

    test "falls back to the whole queue for a label id too large for the database", %{
      conn: conn,
      a: a
    } do
      {:ok, view, _html} = live(conn, ~p"/app/threads/#{a.id}?label=9223372036854775808")

      assert has_element?(view, "[data-testid=staff-thread-queue-position]", "1 of 3")
      assert has_element?(view, "a[data-testid=staff-thread-back][href='/app?at=#{a.id}']")
    end

    test "an anchor that is not in the queue is the same as no anchor", %{
      conn: conn,
      a: a,
      b: b,
      c: c
    } do
      foreign =
        insert_thread(
          tenant_id: insert_tenant().id,
          source: :public_intake,
          state: :active,
          cached_score: 95
        )

      # Another tenant's conversation, not integers, out of range.
      for anchor <- [foreign.id, "x", "1.5", "-1", "0", "9223372036854775808"] do
        {:ok, view, html} =
          live(conn, ~p"/app/threads/#{b.id}?pos=1&after=#{anchor}&before=#{anchor}")

        assert has_element?(view, "[data-testid=staff-thread-queue-position]", "2 of 3")

        assert has_element?(
                 view,
                 "a[data-testid=staff-thread-prev][href='/app/threads/#{a.id}?pos=0&before=#{b.id}%2C#{c.id}']"
               )

        assert has_element?(
                 view,
                 "a[data-testid=staff-thread-next][href='/app/threads/#{c.id}?pos=2&after=#{b.id}%2C#{a.id}']"
               )

        assert has_element?(view, "a[data-testid=staff-thread-back][href='/app?at=#{b.id}']")
        refute html =~ "/app/threads/#{foreign.id}"
      end
    end

    test "never offers a conversation from another tenant", %{conn: conn, a: a} do
      foreign_tenant = insert_tenant()

      foreign =
        insert_thread(
          tenant_id: foreign_tenant.id,
          source: :public_intake,
          state: :active,
          cached_score: 95
        )

      {:ok, view, html} = live(conn, ~p"/app/threads/#{a.id}?pos=0")

      refute html =~ "/app/threads/#{foreign.id}"
      assert has_element?(view, "[data-testid=staff-thread-queue-position]", "1 of 3")
      assert has_element?(view, "[data-testid=staff-thread-prev-none]")
    end
  end
end
