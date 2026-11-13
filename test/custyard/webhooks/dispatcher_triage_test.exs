defmodule Custyard.Webhooks.DispatcherTriageTest do
  @moduledoc """
  Channel resolution and triage in the dispatcher
  (spec-inbound-channels D2, D5, D6, D7).
  """
  use Custyard.DataCase, async: true

  import Custyard.Factory

  alias Custyard.{AuditEvent, Thread, InboundChannelRejection, InboundChannels, Message}
  alias Custyard.{Attachments, MessageAttachment}
  alias Custyard.Attachments.StubClient
  alias Custyard.Email.ThreadHeaders
  alias Custyard.Webhooks.Dispatcher

  @notifications "staff:notifications"

  setup do
    org = insert_organization(name: "Acme")

    route =
      insert_inbound_route(
        organization_id: org.id,
        route_type: :general,
        source: :lettermint,
        lettermint_route_id: "lm_#{System.unique_integer([:positive])}",
        lettermint_route_domain: "r#{System.unique_integer([:positive])}.lettermint.app"
      )

    for purpose <- [:sender_matching, :enrichment, :notification, :audit] do
      insert_inbound_route_webhook(inbound_route_id: route.id, purpose: purpose, enabled: true)
    end

    %{org: org, route: route}
  end

  defp channel!(route, overrides \\ []) do
    insert_inbound_channel(
      Keyword.merge(
        [inbound_route_id: route.id, public_address: "help@acme.example.com", state: :active],
        overrides
      )
    )
  end

  defp delivery(recipient, overrides \\ %{}) do
    Map.merge(
      %{
        from: "Alice <alice@customer.example.com>",
        to: recipient,
        subject: "Hello",
        body: "Customer mail",
        message_id: "<m-#{System.unique_integer([:positive])}@customer.example.com>",
        in_reply_to: nil,
        references: nil,
        headers: %{},
        source: :lettermint,
        metadata: %{
          provider_delivery_id: "dlv-#{System.unique_integer([:positive])}",
          lettermint_message_id: "lm-#{System.unique_integer([:positive])}",
          recipient: recipient,
          subaddress: nil,
          mail_from: "alice@customer.example.com",
          reply_to: nil,
          cc: [],
          authentication: %{
            dkim: "pass",
            dkim_domain: "customer.example.com",
            spf: "pass",
            dmarc: "pass"
          },
          is_spam: false,
          spam_score: 0.3
        }
      },
      overrides
    )
  end

  defp put_metadata(normalized, overrides),
    do: Map.update!(normalized, :metadata, &Map.merge(&1, overrides))

  defp rejections(route), do: InboundChannels.list_rejections_for_route(route.id)

  # Attachment processing completes before dispatch returns; this helper also
  # supports older asynchronous fixture setup.
  defp wait_for_attachments(message_id, attempts \\ 100) do
    case Attachments.list_for_message(message_id) do
      [] when attempts > 0 ->
        Process.sleep(10)
        wait_for_attachments(message_id, attempts - 1)

      rows ->
        rows
    end
  end

  describe "staff-sent capture and manual forward (D6)" do
    @forward_body """
    ---------- Forwarded message ---------
    From: Alice <alice@customer.example.com>
    Date: Mon, 6 Oct 2025
    Subject: Login broken
    To: support@acme.example.com

    I cannot log in since this morning.
    """

    defp staff_delivery(recipient, overrides) do
      delivery(recipient, overrides)
      |> Map.put(:from, "Me <me@acme.example.com>")
      |> put_metadata(%{
        mail_from: "me@acme.example.com",
        authentication: %{
          dkim: "pass",
          dkim_domain: "acme.example.com",
          spf: "pass",
          dmarc: "pass"
        }
      })
    end

    test "a staff's mailbox reply is appended as a staff message, quietly", %{
      org: org,
      route: route
    } do
      channel = channel!(route)

      staff =
        insert_staff_account(
          role: "admin",
          organization_id: org.id,
          email: "me@acme.example.com"
        )

      contact = insert_contact(organization_id: org.id, email: "alice@customer.example.com")

      conv =
        insert_thread(organization_id: org.id, contact_id: contact.id, state: :resolved)

      insert_message(thread_id: conv.id, message_id: "<orig@customer.example.com>")
      Phoenix.PubSub.subscribe(Custyard.PubSub, @notifications)

      payload =
        staff_delivery(InboundChannels.ingress_address(channel), %{
          in_reply_to: "<orig@customer.example.com>",
          body: "Fixed it for you.",
          subject: "Re: Login broken"
        })

      assert {:ok, %Thread{id: conv_id}} = Dispatcher.dispatch(route, payload)
      assert conv_id == conv.id

      message = Repo.get_by!(Message, thread_id: conv.id, triage_class: :staff_sent)
      assert message.source == :staff
      assert message.sender_email == "me@acme.example.com"
      assert message.forwarded_by_staff_id == staff.id
      assert message.forwarded_by_email == "me@acme.example.com"
      assert message.delivery_status == nil
      assert message.body == "Fixed it for you."

      reloaded = Repo.get!(Thread, conv.id)
      assert reloaded.state == :resolved
      assert reloaded.last_staff_action_at
      refute_receive {:new_message, _id}, 100
      assert Repo.aggregate(Custyard.Contact, :count) == 1
    end

    test "a staff mailbox retry resumes failed attachments instead of becoming an own echo",
         %{
           org: org,
           route: route
         } do
      channel = channel!(route)

      insert_staff_account(
        role: "admin",
        organization_id: org.id,
        email: "me@acme.example.com"
      )

      thread = insert_thread(organization_id: org.id, state: :resolved)

      insert_message(
        thread_id: thread.id,
        message_id: "<mailbox-original@example.com>"
      )

      url = StubClient.unique_url()
      StubClient.fail(url, :timeout)

      payload =
        staff_delivery(InboundChannels.ingress_address(channel), %{
          in_reply_to: "<mailbox-original@example.com>"
        })
        |> put_metadata(%{
          attachments: [
            %{
              filename: "reply.txt",
              content_type: "text/plain",
              size: 5,
              content_id: nil,
              url: url
            }
          ]
        })

      assert {:error, :attachment_fetch_failed} = Dispatcher.dispatch(route, payload)

      message =
        Repo.get_by!(Message, thread_id: thread.id, triage_class: :staff_sent)

      assert [%{state: :failed} = attachment] = Attachments.list_for_message(message.id)

      StubClient.put(url, "hello")
      assert {:ok, returned} = Dispatcher.dispatch(route, payload)
      assert returned.id == thread.id
      assert [%{state: :fetched, id: id}] = Attachments.list_for_message(message.id)
      assert id == attachment.id

      assert Repo.aggregate(from(m in Message, where: m.triage_class == :staff_sent), :count) ==
               1
    end

    test "a manual forward creates the thread for the original sender", %{
      org: org,
      route: route
    } do
      channel = channel!(route)

      staff =
        insert_staff_account(
          role: "admin",
          organization_id: org.id,
          email: "me@acme.example.com"
        )

      Phoenix.PubSub.subscribe(Custyard.PubSub, @notifications)

      payload =
        staff_delivery(InboundChannels.ingress_address(channel), %{
          subject: "Fwd: Login broken",
          body: @forward_body
        })
        |> put_metadata(%{is_spam: true, spam_score: 9.0, cc: ["colleague@acme.example.com"]})

      assert {:ok, thread} = Dispatcher.dispatch(route, payload)
      assert thread.subject == "Login broken"
      assert thread.suspect == false
      assert thread.inbound_channel_id == channel.id

      contact = Repo.get!(Custyard.Contact, thread.contact_id)
      assert contact.email == "alice@customer.example.com"

      [message] =
        Repo.all(Ecto.Query.from(m in Message, where: m.thread_id == ^thread.id))

      assert message.source == :email
      assert message.triage_class == :staff_forward
      assert message.sender_email == "Alice <alice@customer.example.com>"
      assert message.body == "I cannot log in since this morning."
      assert message.forwarded_by_staff_id == staff.id
      assert message.forwarded_by_email == "me@acme.example.com"
      assert message.cc_addresses == []
      assert message.authentication == nil
      assert message.spam_score == nil

      refute_receive {:new_message, _id}, 100
    end

    test "an unauthenticated 'staff' address is ordinary customer mail", %{
      org: org,
      route: route
    } do
      channel = channel!(route)

      insert_staff_account(
        role: "admin",
        organization_id: org.id,
        email: "me@acme.example.com"
      )

      payload =
        staff_delivery(InboundChannels.ingress_address(channel), %{
          subject: "Fwd: Login broken",
          body: @forward_body
        })
        |> put_metadata(%{
          authentication: %{dkim: "fail", dkim_domain: "acme.example.com", dmarc: "fail"}
        })

      assert {:ok, thread} = Dispatcher.dispatch(route, payload)
      assert Repo.get!(Custyard.Contact, thread.contact_id).email == "me@acme.example.com"
      assert thread.suspect
    end
  end

  describe "forwarded sent reply (D6)" do
    setup %{org: org, route: route} do
      channel = channel!(route)

      staff =
        insert_staff_account(
          role: "admin",
          organization_id: org.id,
          email: "me@acme.example.com"
        )

      alice = insert_contact(organization_id: org.id, email: "alice@customer.example.com")
      %{channel: channel, staff: staff, alice: alice}
    end

    defp sent_block(overrides) do
      block =
        Keyword.merge(
          [
            from: "Acme Help <help@acme.example.com>",
            date: "Mon, 6 Oct 2025 at 09:12",
            subject: "Re: Login broken",
            to: "Alice <alice@customer.example.com>, Bob <bob@customer.example.com>",
            body: "Fixed, please try again.\n\nMe"
          ],
          overrides
        )

      """
      Filing this, I answered from my phone.

      ---------- Forwarded message ---------
      From: #{block[:from]}
      Date: #{block[:date]}
      Subject: #{block[:subject]}
      To: #{block[:to]}
      Cc: Carol <carol@customer.example.com>

      #{block[:body]}
      """
    end

    # A new Message-ID and delivery id on every call, like a second forward.
    defp sent_forward(channel, block \\ [], overrides \\ %{}) do
      staff_delivery(
        InboundChannels.ingress_address(channel),
        Map.merge(%{subject: "Fwd: Re: Login broken", body: sent_block(block)}, overrides)
      )
      |> put_metadata(%{to: ["help@acme.example.com"], html_body: "<p>Filing this</p>"})
    end

    defp staff_sent_messages(thread) do
      Repo.all(
        from m in Message,
          where: m.thread_id == ^thread.id and m.triage_class == :staff_sent,
          order_by: m.id
      )
    end

    test "is appended to the thread it answers with the original's words, quietly", %{
      org: org,
      route: route,
      channel: channel,
      staff: staff,
      alice: alice
    } do
      thread =
        insert_thread(
          organization_id: org.id,
          contact_id: alice.id,
          subject: "Login broken",
          state: :resolved
        )

      Phoenix.PubSub.subscribe(Custyard.PubSub, @notifications)
      Phoenix.PubSub.subscribe(Custyard.PubSub, "thread:#{thread.id}")
      contacts = Repo.aggregate(Custyard.Contact, :count)

      assert {:ok, %Thread{id: id}} = Dispatcher.dispatch(route, sent_forward(channel))
      assert id == thread.id

      assert [message] = staff_sent_messages(thread)
      assert message.source == :staff
      assert message.body == "Fixed, please try again.\n\nMe"
      assert message.sender_email == "help@acme.example.com"
      assert message.forwarded_by_staff_id == staff.id
      assert message.forwarded_by_email == "me@acme.example.com"
      assert message.to_addresses == ["alice@customer.example.com", "bob@customer.example.com"]
      assert message.cc_addresses == ["carol@customer.example.com"]
      assert message.inbound_channel_id == channel.id
      assert message.delivery_status == nil
      assert message.authentication == nil
      assert message.html_body == nil
      assert message.in_reply_to == nil
      # Made from the original, so it is never sent out as a threading header.
      assert message.message_id =~
               ~r/\Asent-forward-#{thread.id}-[0-9a-f]{32}@custyard\.forward\z/

      assert ThreadHeaders.for_thread(thread.id) == %{}

      reloaded = Repo.get!(Thread, thread.id)
      assert reloaded.state == :resolved
      assert reloaded.last_staff_action_at
      assert reloaded.last_customer_action_at == nil
      assert reloaded.contact_id == alice.id

      assert_receive {:message_added, ^id}
      refute_receive {:new_message, _id}, 100
      assert Repo.aggregate(Custyard.Contact, :count) == contacts
      assert Repo.aggregate(Thread, :count) == 1
      assert Repo.reload!(channel).last_received_at

      assert [audit] = triage_audits(org)
      assert audit.payload["class"] == "staff_sent"
      assert audit.thread_id == thread.id
      assert audit.message_id == message.message_id
      assert rejections(route) == []
    end

    test "a forward that threads by its headers is unwrapped as well", %{
      org: org,
      route: route,
      channel: channel
    } do
      # No contact and another subject: only the headers lead here.
      thread = insert_thread(organization_id: org.id, subject: "Password reset")
      insert_message(thread_id: thread.id, message_id: "<reset@customer.example.com>")

      payload = sent_forward(channel, [], %{references: "<reset@customer.example.com>"})

      assert {:ok, %Thread{id: id}} = Dispatcher.dispatch(route, payload)
      assert id == thread.id
      assert [message] = staff_sent_messages(thread)
      assert message.body == "Fixed, please try again.\n\nMe"
      assert message.sender_email == "help@acme.example.com"
    end

    test "with no thread to answer it is audited and ignored", %{
      org: org,
      route: route,
      channel: channel,
      alice: alice
    } do
      # Alice has a thread, but about something else.
      insert_thread(organization_id: org.id, contact_id: alice.id, subject: "Invoice 42")
      Phoenix.PubSub.subscribe(Custyard.PubSub, @notifications)
      contacts = Repo.aggregate(Custyard.Contact, :count)

      assert {:ignored, :staff_sent_unmatched} = Dispatcher.dispatch(route, sent_forward(channel))

      assert Repo.aggregate(Message, :count) == 0
      assert Repo.aggregate(Thread, :count) == 1
      assert Repo.aggregate(Custyard.Contact, :count) == contacts
      refute Repo.get_by(Custyard.Contact, email: "help@acme.example.com")
      refute Repo.get_by(Custyard.Contact, email: "me@acme.example.com")
      refute_receive {:new_message, _id}, 100

      assert [audit] = triage_audits(org)
      assert audit.payload["class"] == "staff_sent_unmatched"
      assert audit.payload["channel_id"] == channel.id
      assert audit.payload["route_id"] == route.id
      assert audit.thread_id == nil
      refute inspect(audit.payload) =~ "example.com"
      assert Repo.reload!(channel).last_received_at == nil
      assert rejections(route) == []
    end

    test "one recipient with two subjects: the thread with the same subject gets it", %{
      org: org,
      route: route,
      channel: channel,
      alice: alice
    } do
      attrs = [organization_id: org.id, contact_id: alice.id]
      invoice = insert_thread(attrs ++ [subject: "Invoice 42"])
      login = insert_thread(attrs ++ [subject: "Login broken"])

      assert {:ok, %Thread{id: id}} = Dispatcher.dispatch(route, sent_forward(channel))
      assert id == login.id
      assert staff_sent_messages(invoice) == []

      payload = sent_forward(channel, subject: "RE: Invoice 42", body: "Corrected invoice sent.")
      assert {:ok, %Thread{id: id}} = Dispatcher.dispatch(route, payload)
      assert id == invoice.id
      assert [%{body: "Corrected invoice sent."}] = staff_sent_messages(invoice)
      assert [%{body: "Fixed, please try again.\n\nMe"}] = staff_sent_messages(login)
    end

    test "two recipients with the same subject: only the one written to gets it", %{
      org: org,
      route: route,
      channel: channel,
      alice: alice
    } do
      dave = insert_contact(organization_id: org.id, email: "dave@customer.example.com")

      for_alice =
        insert_thread(organization_id: org.id, contact_id: alice.id, subject: "Login broken")

      for_dave =
        insert_thread(organization_id: org.id, contact_id: dave.id, subject: "Login broken")

      payload = sent_forward(channel, to: "Dave <dave@customer.example.com>")
      assert {:ok, %Thread{id: id}} = Dispatcher.dispatch(route, payload)
      assert id == for_dave.id
      assert staff_sent_messages(for_alice) == []

      payload = sent_forward(channel, to: "erin@customer.example.com", date: "Tue, 7 Oct 2025")
      assert {:ignored, :staff_sent_unmatched} = Dispatcher.dispatch(route, payload)
      assert staff_sent_messages(for_alice) == []
      assert [_one] = staff_sent_messages(for_dave)
    end

    test "an unresolved thread is preferred to a resolved one, then the latest activity", %{
      org: org,
      route: route,
      channel: channel,
      alice: alice
    } do
      attrs = [organization_id: org.id, contact_id: alice.id, subject: "Login broken"]
      at = fn seconds -> DateTime.add(~U[2025-10-06 12:00:00Z], seconds, :second) end

      # The resolved thread saw the latest activity; the waiting one is the newest row.
      resolved = insert_thread(attrs ++ [state: :resolved, last_customer_action_at: at.(600)])
      active = insert_thread(attrs ++ [state: :active, last_customer_action_at: at.(300)])
      waiting = insert_thread(attrs ++ [state: :waiting, last_customer_action_at: at.(0)])

      assert {:ok, %Thread{id: id}} = Dispatcher.dispatch(route, sent_forward(channel))
      assert id == active.id
      assert staff_sent_messages(resolved) == []
      assert staff_sent_messages(waiting) == []

      # With nothing unresolved left, the resolved thread with the latest activity gets it.
      for thread <- [active, waiting] do
        thread
        |> Ecto.Changeset.change(state: :resolved, last_staff_action_at: at.(400))
        |> Repo.update!()
      end

      payload = sent_forward(channel, date: "Tue, 7 Oct 2025 at 10:00")
      assert {:ok, %Thread{id: id}} = Dispatcher.dispatch(route, payload)
      assert id == resolved.id
      assert Repo.get!(Thread, resolved.id).state == :resolved
    end

    test "forwarding the same sent message twice adds it once", %{
      org: org,
      route: route,
      channel: channel,
      alice: alice
    } do
      thread =
        insert_thread(organization_id: org.id, contact_id: alice.id, subject: "Login broken")

      first = sent_forward(channel)
      # The second forward has its own Message-ID and delivery id, another
      # note on top and re-wrapped text.
      second =
        sent_forward(channel, body: "Fixed,   please\ntry again.\n\n\nMe")
        |> Map.update!(:body, &String.replace(&1, "Filing this", "Sending this again"))

      refute first.message_id == second.message_id

      assert {:ok, %Thread{id: id}} = Dispatcher.dispatch(route, first)
      assert {:ok, %Thread{id: ^id}} = Dispatcher.dispatch(route, second)
      assert id == thread.id
      assert [message] = staff_sent_messages(thread)
      assert message.body == "Fixed, please try again.\n\nMe"
      assert message.provider_delivery_id == first.metadata.provider_delivery_id

      # A replay of the first delivery is the same message too.
      assert {:ok, %Thread{id: ^id}} = Dispatcher.dispatch(route, first)
      assert [_one] = staff_sent_messages(thread)

      # Another reply with the same words, sent on another day, is kept.
      later = sent_forward(channel, date: "Tue, 7 Oct 2025 at 16:40")
      assert {:ok, %Thread{id: ^id}} = Dispatcher.dispatch(route, later)
      assert [_first, _later] = staff_sent_messages(thread)
    end

    test "attachments on the forward are stored once, and a failed fetch resumes on retry", %{
      org: org,
      route: route,
      channel: channel,
      alice: alice
    } do
      thread =
        insert_thread(organization_id: org.id, contact_id: alice.id, subject: "Login broken")

      url = StubClient.unique_url()
      StubClient.fail(url, :timeout)

      attachment = fn url, name ->
        %{filename: name, content_type: "text/plain", size: 5, content_id: nil, url: url}
      end

      payload = sent_forward(channel) |> put_metadata(%{attachments: [attachment.(url, "a.txt")]})

      assert {:error, :attachment_fetch_failed} = Dispatcher.dispatch(route, payload)
      assert [message] = staff_sent_messages(thread)
      assert [%{state: :failed}] = Attachments.list_for_message(message.id)

      # The provider retries the same delivery: not an own echo, same message.
      StubClient.put(url, "hello")
      assert {:ok, %Thread{}} = Dispatcher.dispatch(route, payload)
      assert [%{id: id}] = staff_sent_messages(thread)
      assert id == message.id
      assert [%{state: :fetched, filename: "a.txt"}] = Attachments.list_for_message(message.id)

      # A second forward of the same message, attached differently, adds nothing.
      other = StubClient.unique_url()
      StubClient.put(other, "hello")
      again = sent_forward(channel) |> put_metadata(%{attachments: [attachment.(other, "b.txt")]})

      assert {:ok, %Thread{}} = Dispatcher.dispatch(route, again)
      assert [_one] = staff_sent_messages(thread)
      assert [%{filename: "a.txt"}] = Attachments.list_for_message(message.id)
    end

    test "a forward of customer mail still runs the customer pipeline", %{
      route: route,
      channel: channel,
      staff: staff
    } do
      payload = sent_forward(channel, from: "Dave <dave@customer.example.com>")

      assert {:ok, thread} = Dispatcher.dispatch(route, payload)
      assert thread.subject == "Re: Login broken"
      assert Repo.get!(Custyard.Contact, thread.contact_id).email == "dave@customer.example.com"

      assert [message] = Repo.all(from m in Message, where: m.thread_id == ^thread.id)
      assert message.triage_class == :staff_forward
      assert message.source == :email
      assert message.forwarded_by_staff_id == staff.id
      assert message.message_id == payload.message_id
      assert message.to_addresses == ["#{channel.ingress_local}@#{route.lettermint_route_domain}"]
      assert message.cc_addresses == []
    end
  end

  describe "attachments (D9)" do
    test "are fetched within the channel cap and the signed URL is never stored", %{
      route: route
    } do
      channel = channel!(route, attachment_limit_mb: 1)
      url = StubClient.unique_url()
      StubClient.put(url, "%PDF-1.4 receipt")

      payload =
        delivery(InboundChannels.ingress_address(channel))
        |> put_metadata(%{
          attachments: [
            %{
              filename: "receipt.pdf",
              content_type: "application/pdf",
              size: 16,
              content_id: nil,
              url: url
            },
            %{
              filename: "huge.mov",
              content_type: "video/quicktime",
              size: 5_000_000,
              content_id: nil,
              url: StubClient.unique_url()
            }
          ]
        })

      assert {:ok, thread} = Dispatcher.dispatch(route, payload)
      message = Repo.get_by!(Message, thread_id: thread.id)

      assert [receipt, huge] = wait_for_attachments(message.id)
      assert %MessageAttachment{state: :fetched, sniffed_type: "application/pdf"} = receipt
      assert %MessageAttachment{state: :skipped, skip_reason: "over_limit"} = huge
      refute inspect(Repo.all(MessageAttachment)) =~ "storage.lettermint.test"
      refute inspect(Repo.all(Message)) =~ "storage.lettermint.test"
    end

    test "a failed attachment withholds success and delivery replay resumes the same slot", %{
      route: route
    } do
      channel = channel!(route)
      url = StubClient.unique_url()
      StubClient.fail(url, :timeout)

      payload =
        delivery(InboundChannels.ingress_address(channel))
        |> put_metadata(%{
          attachments: [
            %{filename: "a.txt", content_type: "text/plain", size: 5, content_id: nil, url: url}
          ]
        })

      assert {:error, :attachment_fetch_failed} = Dispatcher.dispatch(route, payload)
      [message] = Repo.all(Message)
      assert [%{state: :failed} = row] = Attachments.list_for_message(message.id)
      StubClient.put(url, "hello")
      assert {:ok, _thread} = Dispatcher.dispatch(route, payload)
      assert [%{state: :fetched, id: id}] = Attachments.list_for_message(message.id)
      assert id == row.id
      assert Repo.aggregate(Message, :count) == 1
    end

    test "a replayed delivery does not fetch twice", %{route: route} do
      channel = channel!(route)
      url = StubClient.unique_url()
      StubClient.put(url, "hello")

      payload =
        delivery(InboundChannels.ingress_address(channel))
        |> put_metadata(%{
          attachments: [
            %{filename: "a.txt", content_type: "text/plain", size: 5, content_id: nil, url: url}
          ]
        })

      assert {:ok, thread} = Dispatcher.dispatch(route, payload)
      message = Repo.get_by!(Message, thread_id: thread.id)
      assert [_row] = wait_for_attachments(message.id)

      assert {:ok, _same} = Dispatcher.dispatch(route, payload)
      Process.sleep(50)
      assert [_row] = Attachments.list_for_message(message.id)
    end

    test "suspect mail lists its attachments without fetching them", %{route: route} do
      channel = channel!(route)
      url = StubClient.unique_url()
      StubClient.put(url, "MZ payload")

      payload =
        delivery(InboundChannels.ingress_address(channel))
        |> put_metadata(%{
          is_spam: true,
          attachments: [
            %{
              filename: "invoice.exe",
              content_type: "application/octet-stream",
              size: 10,
              content_id: nil,
              url: url
            }
          ]
        })

      assert {:ok, thread} = Dispatcher.dispatch(route, payload)
      assert thread.suspect
      message = Repo.get_by!(Message, thread_id: thread.id)

      assert [
               %MessageAttachment{
                 state: :skipped,
                 skip_reason: "suspect",
                 filename: "invoice.exe"
               }
             ] =
               wait_for_attachments(message.id)
    end
  end

  defp triage_audits(org) do
    Repo.all(
      from a in AuditEvent,
        where: a.tenant_id == ^org.tenant_id and a.event_type == :inbound_triaged
    )
  end

  describe "routes without channels" do
    test "an unconfigured route rejects delivery", %{route: route} do
      assert {:ignored, :no_channel} =
               Dispatcher.dispatch(route, delivery("support@acme.example.com"))

      assert Repo.aggregate(Message, :count) == 0
      assert [%{classification: :no_channel}] = rejections(route)
    end
  end

  describe "channel resolution" do
    test "a recipient matching no channel is logged and ignored", %{route: route} do
      channel = channel!(route)
      recipient = "help+wrongtokenwrongtoken@#{route.lettermint_route_domain}"

      assert {:ignored, :no_channel} = Dispatcher.dispatch(route, delivery(recipient))

      assert [%InboundChannelRejection{} = rejection] = rejections(route)
      assert rejection.classification == :no_channel
      assert rejection.sender_email == "Alice <alice@customer.example.com>"
      assert rejection.recipient == recipient
      assert rejection.subject == "Hello"
      assert rejection.provider_delivery_id =~ "dlv-"
      assert rejection.inbound_channel_id == nil
      assert Repo.aggregate(Thread, :count) == 0
      assert Repo.reload!(channel).last_received_at == nil
    end

    test "a paused channel is logged and ignored", %{route: route} do
      channel = channel!(route, state: :paused)

      assert {:ignored, :channel_paused} =
               Dispatcher.dispatch(route, delivery(InboundChannels.ingress_address(channel)))

      assert [%{classification: :channel_paused, inbound_channel_id: id}] = rejections(route)
      assert id == channel.id
      assert Repo.aggregate(Message, :count) == 0
    end

    test "a revoked channel is logged and ignored", %{route: route} do
      channel = channel!(route, state: :revoked)

      assert {:ignored, :channel_revoked} =
               Dispatcher.dispatch(route, delivery(InboundChannels.ingress_address(channel)))

      assert [%{classification: :channel_revoked, inbound_channel_id: id}] = rejections(route)
      assert id == channel.id
    end

    test "the envelope recipient is used, never To", %{route: route} do
      channel = channel!(route)

      payload =
        delivery("someone-else@acme.example.com")
        |> put_metadata(%{recipient: InboundChannels.ingress_address(channel)})

      assert {:ok, thread} = Dispatcher.dispatch(route, payload)
      assert thread.inbound_channel_id == channel.id
    end
  end

  describe "direct-MX channels (D8)" do
    setup %{route: route} do
      {:ok, route} =
        route
        |> Ecto.Changeset.change(
          lettermint_custom_domain: "help.acme.example.com",
          lettermint_custom_domain_verified_at: ~U[2026-10-20 12:00:00Z]
        )
        |> Repo.update()

      channel =
        channel!(route,
          ingress_kind: :mx,
          public_address: "support@help.acme.example.com",
          state: :awaiting_first_message
        )

      %{route: route, channel: channel}
    end

    test "mail to the public address becomes a thread on the channel",
         %{route: route, channel: channel} do
      assert {:ok, thread} =
               Dispatcher.dispatch(route, delivery("support@help.acme.example.com"))

      assert thread.inbound_channel_id == channel.id
      assert Repo.reload!(channel).state == :active
    end

    test "a +tag on the public address still reaches the channel",
         %{route: route, channel: channel} do
      assert {:ok, thread} =
               Dispatcher.dispatch(route, delivery("support+order-42@help.acme.example.com"))

      assert thread.inbound_channel_id == channel.id
    end

    test "another local part on the custom domain is rejected", %{route: route} do
      assert {:ignored, :no_channel} =
               Dispatcher.dispatch(route, delivery("sales@help.acme.example.com"))

      assert [%{classification: :no_channel}] = rejections(route)
    end
  end

  describe "own outbound echo" do
    test "is audited and ignored without inserting anything", %{org: org, route: route} do
      channel = channel!(route)
      thread = insert_thread(organization_id: org.id, state: :waiting)

      insert_message(
        thread_id: thread.id,
        source: :staff,
        message_id: "<reply-9.c#{thread.id}@custyard.local>"
      )

      Phoenix.PubSub.subscribe(Custyard.PubSub, @notifications)

      payload =
        delivery(InboundChannels.ingress_address(channel), %{
          from: "Acme Help <help@acme.example.com>",
          message_id: "<reply-9.c#{thread.id}@custyard.local>"
        })

      assert {:ignored, :own_echo} = Dispatcher.dispatch(route, payload)

      assert Repo.aggregate(Message, :count) == 1
      assert Repo.aggregate(Thread, :count) == 1
      assert Repo.aggregate(Custyard.Contact, :count) == 0
      assert Repo.reload!(thread).state == :waiting
      assert Repo.reload!(channel).last_received_at == nil
      refute_receive {:new_message, _}, 100

      assert [audit] = triage_audits(org)
      assert audit.thread_id == thread.id
      assert audit.payload["class"] == "own_echo"
      assert audit.payload["channel_id"] == channel.id
      assert audit.payload["route_id"] == route.id
      refute inspect(audit.payload) =~ "acme.example.com"
      assert rejections(route) == []
    end
  end

  describe "provider verification" do
    @gmail_subject "(#314159265) Gmail Forwarding Confirmation - Receive Mail from ops@acme.example.com"
    @gmail_body "Confirm here: https://mail-settings.google.com/mail/vf-abc123 thanks"

    test "is captured on a pending channel and never becomes a thread", %{
      org: org,
      route: route
    } do
      channel = channel!(route, state: :pending_verification)

      payload =
        delivery(InboundChannels.ingress_address(channel), %{
          from: "forwarding-noreply@google.com",
          subject: @gmail_subject,
          body: @gmail_body
        })

      assert {:ignored, :verification_captured} = Dispatcher.dispatch(route, payload)

      channel = Repo.reload!(channel)
      assert channel.verification_code == "314159265"
      assert channel.verification_link == "https://mail-settings.google.com/mail/vf-abc123"
      assert channel.verification_expires_at
      # Capture is not a customer delivery: the channel stays pending.
      assert channel.state == :pending_verification
      assert channel.last_received_at == nil

      assert Repo.aggregate(Thread, :count) == 0
      assert Enum.any?(triage_audits(org), &(&1.payload["class"] == "verification_captured"))
      assert rejections(route) == []
    end

    test "a Proton confirmation arriving after the staff advances is still captured", %{
      route: route
    } do
      channel = channel!(route, state: :awaiting_first_message, provider: :proton)

      payload =
        delivery(InboundChannels.ingress_address(channel), %{
          from: "Proton <no-reply@mail.proton.me>",
          subject: "Confirm forwarding request",
          body: "https://account.proton.me/email-forwarding/accept#confirmation-token",
          headers: %{"Precedence" => "bulk"}
        })

      assert {:ignored, :verification_captured} = Dispatcher.dispatch(route, payload)
      channel = Repo.reload!(channel)

      assert channel.verification_link ==
               "https://account.proton.me/email-forwarding/accept#confirmation-token"

      assert channel.state == :awaiting_first_message
      assert is_nil(channel.last_received_at)
      assert Repo.aggregate(Thread, :count) == 0
      assert rejections(route) == []
    end

    test "on a channel that is not pending it is logged as a provider notice", %{route: route} do
      channel = channel!(route, state: :active)

      payload =
        delivery(InboundChannels.ingress_address(channel), %{
          from: "forwarding-noreply@google.com",
          subject: @gmail_subject,
          body: @gmail_body
        })

      assert {:ignored, :provider_notice} = Dispatcher.dispatch(route, payload)
      assert Repo.reload!(channel).verification_code == nil
      assert [%{classification: :provider_notice, inbound_channel_id: id}] = rejections(route)
      assert id == channel.id
      assert Repo.aggregate(Thread, :count) == 0
    end

    test "an unconfigured route is rejected before provider triage", %{route: route} do
      payload =
        delivery("support@acme.example.com", %{
          from: "no-reply@notify.proton.me",
          subject: "Confirm forwarding",
          body: "https://account.proton.me/confirm/x"
        })

      assert {:ignored, :no_channel} = Dispatcher.dispatch(route, payload)
      assert [%{classification: :no_channel, inbound_channel_id: nil}] = rejections(route)
      assert Repo.aggregate(Thread, :count) == 0
    end
  end

  describe "auto-response" do
    test "is appended without reactivation, notification, or attachment downloads", %{
      org: org,
      route: route
    } do
      channel = channel!(route)
      contact = insert_contact(organization_id: org.id, email: "alice@customer.example.com")

      before = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      thread =
        insert_thread(
          organization_id: org.id,
          contact_id: contact.id,
          state: :waiting,
          last_customer_action_at: before
        )

      insert_message(
        thread_id: thread.id,
        source: :staff,
        message_id: "<op-1.c#{thread.id}@custyard.local>"
      )

      Phoenix.PubSub.subscribe(Custyard.PubSub, @notifications)

      payload =
        delivery(InboundChannels.ingress_address(channel), %{
          subject: "Automatic reply: Hello",
          body: "I am out of office",
          in_reply_to: "<op-1.c#{thread.id}@custyard.local>",
          headers: %{"Auto-Submitted" => "auto-replied"}
        })

      url = StubClient.unique_url()
      test_process = self()

      StubClient.on_fetch(url, fn _limit ->
        send(test_process, :auto_response_attachment_fetched)
        {:error, :timeout}
      end)

      payload =
        put_metadata(payload, %{
          attachments: [
            %{
              filename: "bounce.txt",
              content_type: "text/plain",
              size: 5,
              content_id: nil,
              url: url
            }
          ]
        })

      assert {:ok, returned} = Dispatcher.dispatch(route, payload)
      assert returned.id == thread.id
      refute_received :auto_response_attachment_fetched
      assert Repo.all(MessageAttachment) == []

      reloaded = Repo.reload!(thread)
      assert reloaded.state == :waiting
      assert reloaded.last_customer_action_at == before

      [appended] =
        Repo.all(
          from m in Message,
            where: m.thread_id == ^thread.id and m.source == :email
        )

      assert appended.triage_class == :auto_response
      assert appended.origin == :lettermint
      assert appended.inbound_channel_id == channel.id
      assert appended.in_reply_to == "<op-1.c#{thread.id}@custyard.local>"
      assert appended.provider_delivery_id == payload.metadata.provider_delivery_id
      # No header To in the fixture: the delivery address stands in, minus the token.
      assert appended.to_addresses == [
               "#{channel.ingress_local}@#{route.lettermint_route_domain}"
             ]

      refute_receive {:new_message, _}, 100
      assert Repo.aggregate(Custyard.Contact, :count) == 1
      assert Repo.reload!(channel).last_received_at
      assert rejections(route) == []
    end

    test "that threads to nothing is logged and ignored", %{route: route} do
      channel = channel!(route)

      payload =
        delivery(InboundChannels.ingress_address(channel), %{
          in_reply_to: "<unknown@elsewhere.example>",
          headers: %{"Precedence" => "bulk"}
        })

      assert {:ignored, :auto_response} = Dispatcher.dispatch(route, payload)
      assert [%{classification: :auto_response, inbound_channel_id: id}] = rejections(route)
      assert id == channel.id
      assert Repo.aggregate(Thread, :count) == 0
      assert Repo.aggregate(Message, :count) == 0
    end

    test "a bounce (empty envelope sender) with no thread is logged", %{route: route} do
      channel = channel!(route)

      payload =
        delivery(InboundChannels.ingress_address(channel), %{from: "MAILER-DAEMON@mx.example"})
        |> put_metadata(%{mail_from: ""})

      assert {:ignored, :auto_response} = Dispatcher.dispatch(route, payload)
      assert [%{classification: :auto_response}] = rejections(route)
    end
  end

  describe "suspect mail" do
    test "creates a suspect thread at normal urgency without notification", %{
      route: route
    } do
      channel = channel!(route)
      Phoenix.PubSub.subscribe(Custyard.PubSub, @notifications)

      payload =
        delivery(InboundChannels.ingress_address(channel), %{
          subject: "URGENT: your site is down",
          body: "Critical emergency, click here"
        })
        |> put_metadata(%{is_spam: true, spam_score: 9.8})

      assert {:ok, thread} = Dispatcher.dispatch(route, payload)
      assert thread.suspect == true
      assert thread.urgency == :normal
      assert thread.inbound_channel_id == channel.id

      message = Repo.get_by!(Message, thread_id: thread.id)
      assert message.triage_class == :suspect
      assert message.spam_score == 9.8

      refute_receive {:new_message, _}, 100
    end

    test "the contact created by suspect mail does not whitelist the sender", %{route: route} do
      channel = channel!(route)
      Phoenix.PubSub.subscribe(Custyard.PubSub, @notifications)

      spam = fn subject ->
        delivery(InboundChannels.ingress_address(channel), %{subject: subject})
        |> put_metadata(%{is_spam: true})
      end

      assert {:ok, first} = Dispatcher.dispatch(route, spam.("URGENT one"))
      assert first.suspect == true

      # Second spam from the same sender: a contact row now exists for it.
      assert {:ok, second} = Dispatcher.dispatch(route, spam.("URGENT two"))
      assert second.suspect == true
      assert second.urgency == :normal
      assert Repo.get_by!(Message, thread_id: second.id).triage_class == :suspect

      # A replay of the first delivery is quiet as well.
      assert {:ok, replayed} = Dispatcher.dispatch(route, spam.("URGENT one"))
      assert replayed.suspect == true

      refute_receive {:new_message, _}, 100
    end

    test "an existing contact is exempt", %{org: org, route: route} do
      channel = channel!(route)
      insert_contact(organization_id: org.id, email: "alice@customer.example.com")
      Phoenix.PubSub.subscribe(Custyard.PubSub, @notifications)

      payload =
        delivery(InboundChannels.ingress_address(channel), %{subject: "URGENT outage"})
        |> put_metadata(%{is_spam: true})

      assert {:ok, thread} = Dispatcher.dispatch(route, payload)
      assert thread.suspect == false
      assert thread.urgency == :urgent
      assert Repo.get_by!(Message, thread_id: thread.id).triage_class == :customer

      thread_id = thread.id
      assert_receive {:new_message, ^thread_id}, 500
    end
  end

  describe "customer mail" do
    test "stores the channel and the email facts on the message", %{route: route} do
      channel = channel!(route)
      recipient = InboundChannels.ingress_address(channel)
      Phoenix.PubSub.subscribe(Custyard.PubSub, @notifications)

      payload =
        delivery(recipient)
        |> put_metadata(%{
          to: ["help@acme.example.com"],
          reply_to: "Alice Work <alice.work@customer.example.com>",
          cc: ["boss@customer.example.com", "pm@customer.example.com"],
          spam_score: 1
        })

      assert {:ok, thread} = Dispatcher.dispatch(route, payload)
      assert thread.inbound_channel_id == channel.id
      assert thread.suspect == false

      message = Repo.get_by!(Message, thread_id: thread.id)
      assert message.inbound_channel_id == channel.id
      assert message.triage_class == :customer
      assert message.to_addresses == ["help@acme.example.com"]
      assert message.cc_addresses == ["boss@customer.example.com", "pm@customer.example.com"]
      assert message.reply_to == "alice.work@customer.example.com"
      assert message.spam_score == 1.0

      assert message.authentication == %{
               "dkim" => "pass",
               "dkim_domain" => "customer.example.com",
               "spf" => "pass",
               "dmarc" => "pass"
             }

      thread_id = thread.id
      assert_receive {:new_message, ^thread_id}, 500
    end

    test "omits the authentication map when nothing was learned and ignores a bad reply_to",
         %{route: route} do
      channel = channel!(route)

      payload =
        delivery("support@acme.example.com")
        |> put_metadata(%{
          authentication: %{dkim: nil, dkim_domain: nil, spf: nil, dmarc: nil},
          reply_to: "not an address",
          spam_score: nil
        })

      assert {:ok, thread} = Dispatcher.dispatch(route, payload, channel: channel)
      message = Repo.get_by!(Message, thread_id: thread.id)
      assert message.authentication == nil
      assert message.reply_to == nil
      assert message.spam_score == nil
    end

    test "falls back to the To address when the envelope recipient is absent", %{route: route} do
      channel = channel!(route)
      payload = delivery("support@acme.example.com") |> put_metadata(%{recipient: nil})

      assert {:ok, thread} = Dispatcher.dispatch(route, payload, channel: channel)
      message = Repo.get_by!(Message, thread_id: thread.id)
      assert message.to_addresses == ["support@acme.example.com"]
    end

    test "the ingress token never reaches to_addresses", %{route: route} do
      channel = channel!(route)
      recipient = InboundChannels.ingress_address(channel)

      # No header To at all: the delivery address stands in, minus its subaddress.
      assert {:ok, thread} = Dispatcher.dispatch(route, delivery(recipient))
      message = Repo.get_by!(Message, thread_id: thread.id)

      refute Enum.any?(message.to_addresses, &(&1 =~ channel.ingress_token))
      assert message.to_addresses == ["#{channel.ingress_local}@#{route.lettermint_route_domain}"]
    end

    test "recipient overflow does not reject the delivery", %{route: route} do
      channel = channel!(route)
      addresses = Enum.map(1..51, &"recipient#{&1}@example.com")

      payload =
        delivery(InboundChannels.ingress_address(channel))
        |> put_metadata(%{to: addresses, cc: addresses})

      assert {:ok, thread} = Dispatcher.dispatch(route, payload)
      message = Repo.get_by!(Message, thread_id: thread.id)
      assert message.to_addresses == Enum.take(addresses, 50)
      assert message.cc_addresses == Enum.take(addresses, 50)
    end

    test "a real header To keeps its plus tag on a channel", %{route: route} do
      channel = channel!(route)

      payload =
        delivery("help+billing@acme.example.com")
        |> put_metadata(%{recipient: InboundChannels.ingress_address(channel)})

      assert {:ok, thread} = Dispatcher.dispatch(route, payload)
      message = Repo.get_by!(Message, thread_id: thread.id)
      assert message.to_addresses == ["help+billing@acme.example.com"]
    end

    test "a successful delivery promotes the channel to active", %{route: route} do
      channel = channel!(route, state: :awaiting_first_message)

      assert {:ok, _} =
               Dispatcher.dispatch(route, delivery(InboundChannels.ingress_address(channel)))

      channel = Repo.reload!(channel)
      assert channel.state == :active
      assert channel.last_received_at
      assert channel.verified_at
    end

    test "a replayed delivery is still acknowledged on the same thread", %{route: route} do
      channel = channel!(route)
      payload = delivery(InboundChannels.ingress_address(channel))

      assert {:ok, first} = Dispatcher.dispatch(route, payload)
      assert {:ok, second} = Dispatcher.dispatch(route, payload)
      assert first.id == second.id
      assert Repo.aggregate(Message, :count) == 1
    end
  end
end
