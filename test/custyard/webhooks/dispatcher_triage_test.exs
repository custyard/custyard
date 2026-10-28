defmodule Custyard.Webhooks.DispatcherTriageTest do
  @moduledoc """
  Channel resolution and triage in the dispatcher
  (spec-inbound-channels D2, D5, D6, D7).
  """
  use Custyard.DataCase, async: true

  import Custyard.Factory

  alias Custyard.{AuditEvent, Conversation, InboundChannelRejection, InboundChannels, Message}
  alias Custyard.{Attachments, MessageAttachment}
  alias Custyard.Attachments.StubClient
  alias Custyard.Webhooks.Dispatcher

  @notifications "operator:notifications"

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

  describe "operator-sent capture and manual forward (D6)" do
    @forward_body """
    ---------- Forwarded message ---------
    From: Alice <alice@customer.example.com>
    Date: Mon, 6 Oct 2025
    Subject: Login broken
    To: support@acme.example.com

    I cannot log in since this morning.
    """

    defp operator_delivery(recipient, overrides) do
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

    test "an operator's mailbox reply is appended as an operator message, quietly", %{
      org: org,
      route: route
    } do
      channel = channel!(route)

      operator =
        insert_operator_account(
          role: "admin",
          organization_id: org.id,
          email: "me@acme.example.com"
        )

      contact = insert_contact(organization_id: org.id, email: "alice@customer.example.com")

      conv =
        insert_conversation(organization_id: org.id, contact_id: contact.id, state: :resolved)

      insert_message(conversation_id: conv.id, message_id: "<orig@customer.example.com>")
      Phoenix.PubSub.subscribe(Custyard.PubSub, @notifications)

      payload =
        operator_delivery(InboundChannels.ingress_address(channel), %{
          in_reply_to: "<orig@customer.example.com>",
          body: "Fixed it for you.",
          subject: "Re: Login broken"
        })

      assert {:ok, %Conversation{id: conv_id}} = Dispatcher.dispatch(route, payload)
      assert conv_id == conv.id

      message = Repo.get_by!(Message, conversation_id: conv.id, triage_class: :operator_sent)
      assert message.source == :operator
      assert message.sender_email == "me@acme.example.com"
      assert message.forwarded_by_operator_id == operator.id
      assert message.forwarded_by_email == "me@acme.example.com"
      assert message.delivery_status == nil
      assert message.body == "Fixed it for you."

      reloaded = Repo.get!(Conversation, conv.id)
      assert reloaded.state == :resolved
      assert reloaded.last_operator_action_at
      refute_receive {:new_message, _id}, 100
      assert Repo.aggregate(Custyard.Contact, :count) == 1
    end

    test "an operator mailbox retry resumes failed attachments instead of becoming an own echo",
         %{
           org: org,
           route: route
         } do
      channel = channel!(route)

      insert_operator_account(
        role: "admin",
        organization_id: org.id,
        email: "me@acme.example.com"
      )

      conversation = insert_conversation(organization_id: org.id, state: :resolved)

      insert_message(
        conversation_id: conversation.id,
        message_id: "<mailbox-original@example.com>"
      )

      url = StubClient.unique_url()
      StubClient.fail(url, :timeout)

      payload =
        operator_delivery(InboundChannels.ingress_address(channel), %{
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
        Repo.get_by!(Message, conversation_id: conversation.id, triage_class: :operator_sent)

      assert [%{state: :failed} = attachment] = Attachments.list_for_message(message.id)

      StubClient.put(url, "hello")
      assert {:ok, returned} = Dispatcher.dispatch(route, payload)
      assert returned.id == conversation.id
      assert [%{state: :fetched, id: id}] = Attachments.list_for_message(message.id)
      assert id == attachment.id

      assert Repo.aggregate(from(m in Message, where: m.triage_class == :operator_sent), :count) ==
               1
    end

    test "a manual forward creates the conversation for the original sender", %{
      org: org,
      route: route
    } do
      channel = channel!(route)

      operator =
        insert_operator_account(
          role: "admin",
          organization_id: org.id,
          email: "me@acme.example.com"
        )

      Phoenix.PubSub.subscribe(Custyard.PubSub, @notifications)

      payload =
        operator_delivery(InboundChannels.ingress_address(channel), %{
          subject: "Fwd: Login broken",
          body: @forward_body
        })
        |> put_metadata(%{is_spam: true, spam_score: 9.0, cc: ["colleague@acme.example.com"]})

      assert {:ok, conversation} = Dispatcher.dispatch(route, payload)
      assert conversation.subject == "Login broken"
      assert conversation.suspect == false
      assert conversation.inbound_channel_id == channel.id

      contact = Repo.get!(Custyard.Contact, conversation.contact_id)
      assert contact.email == "alice@customer.example.com"

      [message] =
        Repo.all(Ecto.Query.from(m in Message, where: m.conversation_id == ^conversation.id))

      assert message.source == :email
      assert message.triage_class == :operator_forward
      assert message.sender_email == "Alice <alice@customer.example.com>"
      assert message.body == "I cannot log in since this morning."
      assert message.forwarded_by_operator_id == operator.id
      assert message.forwarded_by_email == "me@acme.example.com"
      assert message.cc_addresses == []
      assert message.authentication == nil
      assert message.spam_score == nil

      refute_receive {:new_message, _id}, 100
    end

    test "an unauthenticated 'operator' address is ordinary customer mail", %{
      org: org,
      route: route
    } do
      channel = channel!(route)

      insert_operator_account(
        role: "admin",
        organization_id: org.id,
        email: "me@acme.example.com"
      )

      payload =
        operator_delivery(InboundChannels.ingress_address(channel), %{
          subject: "Fwd: Login broken",
          body: @forward_body
        })
        |> put_metadata(%{
          authentication: %{dkim: "fail", dkim_domain: "acme.example.com", dmarc: "fail"}
        })

      assert {:ok, conversation} = Dispatcher.dispatch(route, payload)
      assert Repo.get!(Custyard.Contact, conversation.contact_id).email == "me@acme.example.com"
      assert conversation.suspect
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

      assert {:ok, conversation} = Dispatcher.dispatch(route, payload)
      message = Repo.get_by!(Message, conversation_id: conversation.id)

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
      assert {:ok, _conversation} = Dispatcher.dispatch(route, payload)
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

      assert {:ok, conversation} = Dispatcher.dispatch(route, payload)
      message = Repo.get_by!(Message, conversation_id: conversation.id)
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

      assert {:ok, conversation} = Dispatcher.dispatch(route, payload)
      assert conversation.suspect
      message = Repo.get_by!(Message, conversation_id: conversation.id)

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
        where: a.organization_id == ^org.id and a.event_type == :inbound_triaged
    )
  end

  describe "legacy routes" do
    test "a route without channels behaves as before", %{route: route} do
      assert {:ok, conversation} =
               Dispatcher.dispatch(route, delivery("support@acme.example.com"))

      assert conversation.inbound_channel_id == nil

      message = Repo.get_by!(Message, conversation_id: conversation.id)
      assert message.inbound_channel_id == nil
      assert message.triage_class == :customer
      assert rejections(route) == []
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
      assert Repo.aggregate(Conversation, :count) == 0
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

      assert {:ok, conversation} = Dispatcher.dispatch(route, payload)
      assert conversation.inbound_channel_id == channel.id
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

    test "mail to the public address becomes a conversation on the channel",
         %{route: route, channel: channel} do
      assert {:ok, conversation} =
               Dispatcher.dispatch(route, delivery("support@help.acme.example.com"))

      assert conversation.inbound_channel_id == channel.id
      assert Repo.reload!(channel).state == :active
    end

    test "a +tag on the public address still reaches the channel",
         %{route: route, channel: channel} do
      assert {:ok, conversation} =
               Dispatcher.dispatch(route, delivery("support+order-42@help.acme.example.com"))

      assert conversation.inbound_channel_id == channel.id
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
      conversation = insert_conversation(organization_id: org.id, state: :waiting)

      insert_message(
        conversation_id: conversation.id,
        source: :operator,
        message_id: "<reply-9.c#{conversation.id}@custyard.local>"
      )

      Phoenix.PubSub.subscribe(Custyard.PubSub, @notifications)

      payload =
        delivery(InboundChannels.ingress_address(channel), %{
          from: "Acme Help <help@acme.example.com>",
          message_id: "<reply-9.c#{conversation.id}@custyard.local>"
        })

      assert {:ignored, :own_echo} = Dispatcher.dispatch(route, payload)

      assert Repo.aggregate(Message, :count) == 1
      assert Repo.aggregate(Conversation, :count) == 1
      assert Repo.aggregate(Custyard.Contact, :count) == 0
      assert Repo.reload!(conversation).state == :waiting
      assert Repo.reload!(channel).last_received_at == nil
      refute_receive {:new_message, _}, 100

      assert [audit] = triage_audits(org)
      assert audit.conversation_id == conversation.id
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

    test "is captured on a pending channel and never becomes a conversation", %{
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

      assert Repo.aggregate(Conversation, :count) == 0
      assert Enum.any?(triage_audits(org), &(&1.payload["class"] == "verification_captured"))
      assert rejections(route) == []
    end

    test "a Proton confirmation arriving after the operator advances is still captured", %{
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
      assert Repo.aggregate(Conversation, :count) == 0
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
      assert Repo.aggregate(Conversation, :count) == 0
    end

    test "on a legacy route it is logged as a provider notice", %{route: route} do
      payload =
        delivery("support@acme.example.com", %{
          from: "no-reply@notify.proton.me",
          subject: "Confirm forwarding",
          body: "https://account.proton.me/confirm/x"
        })

      assert {:ignored, :provider_notice} = Dispatcher.dispatch(route, payload)
      assert [%{classification: :provider_notice, inbound_channel_id: nil}] = rejections(route)
      assert Repo.aggregate(Conversation, :count) == 0
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

      conversation =
        insert_conversation(
          organization_id: org.id,
          contact_id: contact.id,
          state: :waiting,
          last_customer_action_at: before
        )

      insert_message(
        conversation_id: conversation.id,
        source: :operator,
        message_id: "<op-1.c#{conversation.id}@custyard.local>"
      )

      Phoenix.PubSub.subscribe(Custyard.PubSub, @notifications)

      payload =
        delivery(InboundChannels.ingress_address(channel), %{
          subject: "Automatic reply: Hello",
          body: "I am out of office",
          in_reply_to: "<op-1.c#{conversation.id}@custyard.local>",
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
      assert returned.id == conversation.id
      refute_received :auto_response_attachment_fetched
      assert Repo.all(MessageAttachment) == []

      reloaded = Repo.reload!(conversation)
      assert reloaded.state == :waiting
      assert reloaded.last_customer_action_at == before

      [appended] =
        Repo.all(
          from m in Message,
            where: m.conversation_id == ^conversation.id and m.source == :email
        )

      assert appended.triage_class == :auto_response
      assert appended.origin == :lettermint
      assert appended.inbound_channel_id == channel.id
      assert appended.in_reply_to == "<op-1.c#{conversation.id}@custyard.local>"
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
      assert Repo.aggregate(Conversation, :count) == 0
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
    test "creates a suspect conversation at normal urgency without notification", %{
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

      assert {:ok, conversation} = Dispatcher.dispatch(route, payload)
      assert conversation.suspect == true
      assert conversation.urgency == :normal
      assert conversation.inbound_channel_id == channel.id

      message = Repo.get_by!(Message, conversation_id: conversation.id)
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
      assert Repo.get_by!(Message, conversation_id: second.id).triage_class == :suspect

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

      assert {:ok, conversation} = Dispatcher.dispatch(route, payload)
      assert conversation.suspect == false
      assert conversation.urgency == :urgent
      assert Repo.get_by!(Message, conversation_id: conversation.id).triage_class == :customer

      conversation_id = conversation.id
      assert_receive {:new_message, ^conversation_id}, 500
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

      assert {:ok, conversation} = Dispatcher.dispatch(route, payload)
      assert conversation.inbound_channel_id == channel.id
      assert conversation.suspect == false

      message = Repo.get_by!(Message, conversation_id: conversation.id)
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

      conversation_id = conversation.id
      assert_receive {:new_message, ^conversation_id}, 500
    end

    test "omits the authentication map when nothing was learned and ignores a bad reply_to",
         %{route: route} do
      payload =
        delivery("support@acme.example.com")
        |> put_metadata(%{
          authentication: %{dkim: nil, dkim_domain: nil, spf: nil, dmarc: nil},
          reply_to: "not an address",
          spam_score: nil
        })

      assert {:ok, conversation} = Dispatcher.dispatch(route, payload)
      message = Repo.get_by!(Message, conversation_id: conversation.id)
      assert message.authentication == nil
      assert message.reply_to == nil
      assert message.spam_score == nil
    end

    test "falls back to the To address when the envelope recipient is absent", %{route: route} do
      payload = delivery("support@acme.example.com") |> put_metadata(%{recipient: nil})

      assert {:ok, conversation} = Dispatcher.dispatch(route, payload)
      message = Repo.get_by!(Message, conversation_id: conversation.id)
      assert message.to_addresses == ["support@acme.example.com"]
    end

    test "the ingress token never reaches to_addresses", %{route: route} do
      channel = channel!(route)
      recipient = InboundChannels.ingress_address(channel)

      # No header To at all: the delivery address stands in, minus its subaddress.
      assert {:ok, conversation} = Dispatcher.dispatch(route, delivery(recipient))
      message = Repo.get_by!(Message, conversation_id: conversation.id)

      refute Enum.any?(message.to_addresses, &(&1 =~ channel.ingress_token))
      assert message.to_addresses == ["#{channel.ingress_local}@#{route.lettermint_route_domain}"]
    end

    test "recipient overflow does not reject the delivery", %{route: route} do
      channel = channel!(route)
      addresses = Enum.map(1..51, &"recipient#{&1}@example.com")

      payload =
        delivery(InboundChannels.ingress_address(channel))
        |> put_metadata(%{to: addresses, cc: addresses})

      assert {:ok, conversation} = Dispatcher.dispatch(route, payload)
      message = Repo.get_by!(Message, conversation_id: conversation.id)
      assert message.to_addresses == Enum.take(addresses, 50)
      assert message.cc_addresses == Enum.take(addresses, 50)
    end

    test "a real header To keeps its plus tag on a channel", %{route: route} do
      channel = channel!(route)

      payload =
        delivery("help+billing@acme.example.com")
        |> put_metadata(%{recipient: InboundChannels.ingress_address(channel)})

      assert {:ok, conversation} = Dispatcher.dispatch(route, payload)
      message = Repo.get_by!(Message, conversation_id: conversation.id)
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

    test "a replayed delivery is still acknowledged on the same conversation", %{route: route} do
      channel = channel!(route)
      payload = delivery(InboundChannels.ingress_address(channel))

      assert {:ok, first} = Dispatcher.dispatch(route, payload)
      assert {:ok, second} = Dispatcher.dispatch(route, payload)
      assert first.id == second.id
      assert Repo.aggregate(Message, :count) == 1
    end
  end
end
