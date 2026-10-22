defmodule Custyard.Email.DeliveryStatusTest do
  use Custyard.DataCase, async: true

  import Custyard.Factory

  alias Custyard.{AuditEvent, Contact, Message, Repo}
  alias Custyard.Email.DeliveryStatus

  @provider_id "lm-msg-0a1b2c3d"

  describe "rank/1 and terminal?/1" do
    test "ranks the progressive statuses in order" do
      assert DeliveryStatus.rank(:pending) == 0
      assert DeliveryStatus.rank(:sending) == 1
      assert DeliveryStatus.rank(:sent) == 2
      assert DeliveryStatus.rank(:delivered) == 3
    end

    test "terminal statuses and withheld have no rank" do
      for status <- [:bounced, :suppressed, :failed, :withheld] do
        assert DeliveryStatus.rank(status) == nil
      end
    end

    test "bounced, suppressed and failed are terminal" do
      assert DeliveryStatus.terminal?(:bounced)
      assert DeliveryStatus.terminal?(:suppressed)
      assert DeliveryStatus.terminal?(:failed)
      refute DeliveryStatus.terminal?(:delivered)
      refute DeliveryStatus.terminal?(:withheld)
    end
  end

  describe "advance?/2" do
    test "transition table" do
      table = [
        {:sent, :delivered, true},
        {:delivered, :sent, false},
        {:sent, :sent, false},
        {:sent, :bounced, true},
        {:bounced, :delivered, false},
        {:bounced, :failed, true},
        {:pending, :sent, true},
        {:sending, :delivered, true},
        {:suppressed, :suppressed, false},
        {:bounced, :bounced, false},
        {:failed, :suppressed, true}
      ]

      for {current, incoming, expected} <- table do
        assert DeliveryStatus.advance?(current, incoming) == expected,
               "expected advance?(#{current}, #{incoming}) to be #{expected}"
      end
    end

    test "withheld is never changed by a provider event" do
      for incoming <- Message.delivery_statuses() do
        refute DeliveryStatus.advance?(:withheld, incoming)
      end
    end

    test "inbound messages (nil status) are never changed" do
      for incoming <- Message.delivery_statuses() do
        refute DeliveryStatus.advance?(nil, incoming)
      end
    end
  end

  describe "event_status/1" do
    test "maps lifecycle events to statuses" do
      assert DeliveryStatus.event_status("message.sent") == :sent
      assert DeliveryStatus.event_status("message.delivered") == :delivered
      assert DeliveryStatus.event_status("message.hard_bounced") == :bounced
      assert DeliveryStatus.event_status("message.failed") == :failed
      assert DeliveryStatus.event_status("message.policy_rejected") == :failed
      assert DeliveryStatus.event_status("message.suppressed") == :suppressed
    end

    test "non-status events map to nil" do
      for event <- [
            "message.created",
            "message.soft_bounced",
            "message.spam_complaint",
            "message.opened",
            "message.clicked",
            "message.unsubscribed",
            "message.auto_replied",
            "message.inbound",
            "something.unknown",
            nil
          ] do
        assert DeliveryStatus.event_status(event) == nil
      end
    end
  end

  describe "apply_event/1" do
    setup do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, email: "alice@customer.com")
      conversation = insert_conversation(organization_id: org.id, contact_id: contact.id)

      outbound =
        insert_message(
          conversation_id: conversation.id,
          source: :operator,
          sender_email: "support@acme.com",
          message_id: "<reply-001@custyard.local>",
          body: "We can help with that.",
          delivery_status: :sent,
          lettermint_message_id: @provider_id
        )

      {:ok, org: org, conversation: conversation, outbound: outbound}
    end

    test "delivered advances the message and writes an audit event with only allowed keys", %{
      org: org,
      conversation: conversation,
      outbound: outbound
    } do
      envelope = envelope("message.delivered", "evt-1", delivered_data())

      assert {:ok, :updated, %Message{} = updated} = DeliveryStatus.apply_event(envelope)
      assert updated.id == outbound.id
      assert updated.delivery_status == :delivered
      assert Repo.get!(Message, outbound.id).delivery_status == :delivered

      [audit] = Repo.all(AuditEvent)
      assert audit.event_type == :delivery_status_updated
      assert audit.source == "lettermint"
      assert audit.message_id == "<reply-001@custyard.local>"
      assert audit.conversation_id == conversation.id
      assert audit.organization_id == org.id

      assert audit.payload == %{
               "event" => "message.delivered",
               "delivery_id" => "evt-1",
               "from" => "sent",
               "to" => "delivered",
               "reason" => nil,
               "reason_code" => nil,
               "status_code" => 250,
               "enhanced_status_code" => "2.0.0"
             }

      encoded = Jason.encode!(audit.payload)
      refute encoded =~ "alice@customer.com"
      refute encoded =~ "Help with billing"
      refute encoded =~ "OK queued"
    end

    test "a retried identical event is ignored and writes no second audit event" do
      envelope = envelope("message.delivered", "evt-1", delivered_data())

      assert {:ok, :updated, _} = DeliveryStatus.apply_event(envelope)
      assert {:ok, :ignored, :not_advanced} = DeliveryStatus.apply_event(envelope)
      assert Repo.aggregate(AuditEvent, :count) == 1
    end

    test "out-of-order sent after delivered is ignored", %{outbound: outbound} do
      assert {:ok, :updated, _} =
               DeliveryStatus.apply_event(
                 envelope("message.delivered", "evt-1", delivered_data())
               )

      assert {:ok, :ignored, :not_advanced} =
               DeliveryStatus.apply_event(
                 envelope("message.sent", "evt-0", %{
                   "message_id" => @provider_id,
                   "recipient" => "alice@customer.com"
                 })
               )

      assert Repo.get!(Message, outbound.id).delivery_status == :delivered
    end

    test "hard bounce is terminal and records the reason fields", %{outbound: outbound} do
      data = %{
        "message_id" => @provider_id,
        "recipient" => "alice@customer.com",
        "response" => %{
          "status_code" => 550,
          "enhanced_status_code" => "5.1.1",
          "content" => "550 5.1.1 user unknown"
        }
      }

      assert {:ok, :updated, updated} =
               DeliveryStatus.apply_event(envelope("message.hard_bounced", "evt-b", data))

      assert updated.delivery_status == :bounced
      assert Repo.get!(Message, outbound.id).delivery_status == :bounced

      [audit] = Repo.all(AuditEvent)
      assert audit.payload["status_code"] == 550
      assert audit.payload["enhanced_status_code"] == "5.1.1"
      refute Map.has_key?(audit.payload, "content")
      refute Map.has_key?(audit.payload, "recipient")
    end

    test "a retried terminal event is ignored and writes no second audit event", %{
      outbound: outbound
    } do
      envelope = envelope("message.hard_bounced", "evt-b", %{"message_id" => @provider_id})

      assert {:ok, :updated, _} = DeliveryStatus.apply_event(envelope)
      assert {:ok, :ignored, :not_advanced} = DeliveryStatus.apply_event(envelope)

      assert Repo.get!(Message, outbound.id).delivery_status == :bounced
      assert Repo.aggregate(AuditEvent, :count) == 1
    end

    test "a later terminal event replaces an earlier terminal status", %{outbound: outbound} do
      assert {:ok, :updated, _} =
               DeliveryStatus.apply_event(
                 envelope("message.hard_bounced", "evt-b", %{"message_id" => @provider_id})
               )

      assert {:ok, :updated, updated} =
               DeliveryStatus.apply_event(
                 envelope("message.failed", "evt-f", %{
                   "message_id" => @provider_id,
                   "reason" => "rejected",
                   "reason_code" => "policy"
                 })
               )

      assert updated.delivery_status == :failed
      assert Repo.get!(Message, outbound.id).delivery_status == :failed

      audits = Repo.all(AuditEvent)

      assert Enum.map(audits, &{&1.payload["from"], &1.payload["to"]}) |> Enum.sort() ==
               [{"bounced", "failed"}, {"sent", "bounced"}]

      failed = Enum.find(audits, &(&1.payload["to"] == "failed"))
      assert failed.payload["reason"] == "rejected"
      assert failed.payload["reason_code"] == "policy"
    end

    test "unknown provider message id is ignored" do
      assert {:ok, :ignored, :unknown_message} =
               DeliveryStatus.apply_event(
                 envelope("message.delivered", "evt-x", %{"message_id" => "lm-nope"})
               )

      assert Repo.aggregate(AuditEvent, :count) == 0
    end

    test "missing message id is ignored" do
      assert {:ok, :ignored, :missing_message_id} =
               DeliveryStatus.apply_event(envelope("message.delivered", "evt-x", %{}))

      assert {:ok, :ignored, :missing_message_id} =
               DeliveryStatus.apply_event(%{"event" => "message.delivered", "data" => "junk"})
    end

    test "an inbound message with the same provider id is never touched", %{
      conversation: conversation,
      outbound: outbound
    } do
      inbound =
        insert_message(
          conversation_id: conversation.id,
          source: :email,
          origin: :lettermint,
          sender_email: "alice@customer.com",
          message_id: "<inbound-001@customer.com>",
          body: "Hello",
          delivery_status: nil,
          lettermint_message_id: @provider_id
        )

      assert is_nil(inbound.delivery_status)

      assert {:ok, :updated, updated} =
               DeliveryStatus.apply_event(
                 envelope("message.delivered", "evt-1", delivered_data())
               )

      assert updated.id == outbound.id
      assert Repo.get!(Message, inbound.id).delivery_status == nil
      assert Repo.get!(Message, outbound.id).delivery_status == :delivered
    end

    test "only an inbound message matches: ignored as unknown", %{
      conversation: conversation,
      outbound: outbound
    } do
      Repo.delete!(outbound)

      insert_message(
        conversation_id: conversation.id,
        source: :email,
        sender_email: "alice@customer.com",
        message_id: "<inbound-002@customer.com>",
        body: "Hello",
        lettermint_message_id: @provider_id
      )

      assert {:ok, :ignored, :unknown_message} =
               DeliveryStatus.apply_event(
                 envelope("message.delivered", "evt-1", delivered_data())
               )
    end

    test "soft bounce is ignored", %{outbound: outbound} do
      assert {:ok, :ignored, :unknown_event} =
               DeliveryStatus.apply_event(
                 envelope("message.soft_bounced", "evt-s", %{"message_id" => @provider_id})
               )

      assert Repo.get!(Message, outbound.id).delivery_status == :sent
      assert Repo.aggregate(AuditEvent, :count) == 0
    end

    test "withheld messages are not advanced", %{conversation: conversation} do
      insert_message(
        conversation_id: conversation.id,
        source: :operator,
        body: "Recorded but not emailed",
        delivery_status: :withheld,
        lettermint_message_id: "lm-withheld"
      )

      assert {:ok, :ignored, :not_advanced} =
               DeliveryStatus.apply_event(
                 envelope("message.delivered", "evt-w", %{"message_id" => "lm-withheld"})
               )
    end

    test "emits telemetry for updated and ignored outcomes" do
      ref = make_ref()
      parent = self()

      :telemetry.attach(
        "delivery-status-test-#{inspect(ref)}",
        [:custyard, :email, :delivery_status, :event],
        fn _name, measurements, metadata, _config ->
          send(parent, {ref, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("delivery-status-test-#{inspect(ref)}") end)

      envelope = envelope("message.delivered", "evt-1", delivered_data())
      assert {:ok, :updated, _} = DeliveryStatus.apply_event(envelope)
      assert_receive {^ref, %{count: 1}, %{event: "message.delivered", result: :updated}}

      assert {:ok, :ignored, _} = DeliveryStatus.apply_event(envelope)
      assert_receive {^ref, %{count: 1}, %{event: "message.delivered", result: :ignored}}
    end

    test "non-map or event-less payload is an error" do
      assert {:error, :invalid_payload} = DeliveryStatus.apply_event(%{})
      assert {:error, :invalid_payload} = DeliveryStatus.apply_event(%{"event" => 42})
      assert {:error, :invalid_payload} = DeliveryStatus.apply_event([])
    end
  end

  describe "contact email status" do
    setup do
      org = insert_organization()
      alice = insert_contact(organization_id: org.id, email: "Alice@Customer.com")
      bob = insert_contact(organization_id: org.id, email: "bob@customer.com")
      conversation = insert_conversation(organization_id: org.id, contact_id: alice.id)

      insert_message(
        conversation_id: conversation.id,
        source: :operator,
        sender_email: "support@acme.com",
        message_id: "<reply-002@custyard.local>",
        body: "We can help with that.",
        delivery_status: :sent,
        lettermint_message_id: @provider_id,
        to_addresses: ["alice@customer.com"],
        cc_addresses: ["bob@customer.com"]
      )

      {:ok, org: org, alice: alice, bob: bob, conversation: conversation}
    end

    test "a hard bounce flags the recipient at the event time", %{alice: alice, bob: bob} do
      DeliveryStatus.apply_event(
        envelope("message.hard_bounced", "evt-b", recipient_data("alice@customer.com"))
      )

      alice = Repo.reload!(alice)
      assert alice.email_status == :bounced
      assert alice.email_status_at == ~U[2026-10-20 12:00:00Z]
      assert Repo.reload!(bob).email_status == :valid
    end

    test "a bounced CC address flags that contact, not the conversation's", %{
      alice: alice,
      bob: bob
    } do
      DeliveryStatus.apply_event(
        envelope("message.hard_bounced", "evt-b", recipient_data(" BOB@customer.com "))
      )

      assert Repo.reload!(bob).email_status == :bounced
      assert Repo.reload!(alice).email_status == :valid
    end

    test "a suppression flags the recipient as suppressed", %{alice: alice} do
      DeliveryStatus.apply_event(
        envelope("message.suppressed", "evt-s", recipient_data("alice@customer.com"))
      )

      assert Repo.reload!(alice).email_status == :suppressed
    end

    test "the same address in another organization is not flagged" do
      other = insert_contact(email: "alice@customer.com")

      DeliveryStatus.apply_event(
        envelope("message.hard_bounced", "evt-b", recipient_data("alice@customer.com"))
      )

      assert Repo.reload!(other).email_status == :valid
    end

    test "a second recipient's bounce applies after the message is already bounced", %{
      alice: alice,
      bob: bob
    } do
      assert {:ok, :updated, _} =
               DeliveryStatus.apply_event(
                 envelope("message.hard_bounced", "evt-1", recipient_data("bob@customer.com"))
               )

      assert {:ok, :ignored, :not_advanced} =
               DeliveryStatus.apply_event(
                 envelope("message.hard_bounced", "evt-2", recipient_data("alice@customer.com"))
               )

      assert Repo.reload!(alice).email_status == :bounced
      assert Repo.reload!(bob).email_status == :bounced
    end

    test "a later delivery clears the flag", %{alice: alice} do
      DeliveryStatus.apply_event(
        envelope("message.hard_bounced", "evt-b", recipient_data("alice@customer.com"))
      )

      DeliveryStatus.apply_event(
        envelope(
          "message.delivered",
          "evt-d",
          recipient_data("alice@customer.com"),
          "2026-10-21T09:00:00Z"
        )
      )

      alice = Repo.reload!(alice)
      assert alice.email_status == :valid
      assert alice.email_status_at == ~U[2026-10-21 09:00:00Z]
    end

    test "a delivery event older than the bounce does not clear it", %{alice: alice} do
      DeliveryStatus.apply_event(
        envelope("message.hard_bounced", "evt-b", recipient_data("alice@customer.com"))
      )

      DeliveryStatus.apply_event(
        envelope(
          "message.delivered",
          "evt-d",
          recipient_data("alice@customer.com"),
          "2026-10-19T09:00:00Z"
        )
      )

      assert Repo.reload!(alice).email_status == :bounced
    end

    test "sent and failed events leave the address alone", %{alice: alice} do
      for event <- ["message.sent", "message.failed"] do
        DeliveryStatus.apply_event(envelope(event, event, recipient_data("alice@customer.com")))
      end

      assert Repo.reload!(alice).email_status == :valid
    end

    test "an unknown provider message flags nothing", %{alice: alice} do
      data = %{recipient_data("alice@customer.com") | "message_id" => "lm-unknown"}
      DeliveryStatus.apply_event(envelope("message.hard_bounced", "evt-b", data))

      assert Repo.reload!(alice).email_status == :valid
    end

    test "changing the contact's address clears the flag", %{alice: alice} do
      DeliveryStatus.apply_event(
        envelope("message.hard_bounced", "evt-b", recipient_data("alice@customer.com"))
      )

      {:ok, updated} =
        alice
        |> Repo.reload!()
        |> Contact.update_changeset(%{email: "alice@new.example.com"})
        |> Repo.update()

      assert updated.email_status == :valid
      assert updated.email_status_at == nil
    end
  end

  defp envelope(event, delivery_id, data, timestamp \\ "2026-10-20T12:00:00Z") do
    %{
      "id" => delivery_id,
      "event" => event,
      "timestamp" => timestamp,
      "sandbox" => false,
      "sandbox_result" => nil,
      "context" => %{
        "scope" => "route",
        "team_id" => "team-1",
        "project_id" => "proj-1",
        "route_id" => "route-1"
      },
      "data" => data
    }
  end

  defp delivered_data do
    %{
      "message_id" => @provider_id,
      "subject" => "Help with billing",
      "recipient" => "alice@customer.com",
      "metadata" => %{"customer" => "alice@customer.com"},
      "response" => %{
        "status_code" => 250,
        "enhanced_status_code" => "2.0.0",
        "content" => "250 2.0.0 OK queued as 12345"
      }
    }
  end

  defp recipient_data(recipient) do
    %{"message_id" => @provider_id, "recipient" => recipient}
  end
end
