defmodule Custyard.Email.DeliveryStatusNoticeTest do
  @moduledoc """
  The staff notice for a bounced or suppressed reply
  (spec-conversation-loop, "Bounce and Suppression Handling").
  """
  # async: false - turns on :email_enabled for the whole VM.
  use Custyard.DataCase, async: false

  import Custyard.Factory
  import Swoosh.TestAssertions

  alias Custyard.Email.DeliveryStatus

  defp apply_event(envelope) do
    DeliveryStatus.apply_event(envelope, tenant_id: Process.get(:factory_tenant_id))
  end

  @provider_id "lm-msg-notice"

  setup do
    Application.put_env(:custyard, :email_enabled, true)
    on_exit(fn -> Application.delete_env(:custyard, :email_enabled) end)
  end

  describe "staff notice" do
    setup do
      org = insert_organization(name: "Acme Corp")
      configure_tenant_email(org.tenant_id)
      insert_staff_account(tenant_id: org.tenant_id, email: "staff@tenant.example")
      contact = insert_contact(organization_id: org.id, email: "alice@customer.com")

      conversation =
        insert_conversation(
          organization_id: org.id,
          contact_id: contact.id,
          subject: "Billing question"
        )

      insert_message(
        conversation_id: conversation.id,
        source: :staff,
        sender_email: "support@acme.com",
        body: "We can help with that.",
        delivery_status: :sent,
        lettermint_message_id: @provider_id
      )

      :ok
    end

    test "a bounce sends one notice, however often the event is retried" do
      event = envelope("message.hard_bounced", "evt-b", recipient_data("alice@customer.com"))

      assert {:ok, :updated, _} = apply_event(event)
      assert {:ok, :ignored, :not_advanced} = apply_event(event)

      assert_email_sent(fn email ->
        assert email.subject == "Reply bounced: Billing question"
        assert email.text_body =~ "alice@customer.com"
      end)

      assert_no_email_sent()
    end

    test "a suppression sends a notice" do
      apply_event(envelope("message.suppressed", "evt-s", recipient_data("alice@customer.com")))

      assert_email_sent(subject: "Reply suppressed: Billing question")
    end

    test "deliveries and failures send none" do
      apply_event(envelope("message.delivered", "evt-d", recipient_data("alice@customer.com")))

      apply_event(envelope("message.failed", "evt-f", recipient_data("alice@customer.com")))

      assert_no_email_sent()
    end
  end

  describe "staff notice per recipient" do
    setup do
      org = insert_organization(name: "Acme Corp")
      configure_tenant_email(org.tenant_id)
      insert_staff_account(tenant_id: org.tenant_id, email: "staff@tenant.example")
      contact = insert_contact(organization_id: org.id, email: "alice@customer.com")

      conversation =
        insert_conversation(
          organization_id: org.id,
          contact_id: contact.id,
          subject: "Billing question"
        )

      insert_message(
        conversation_id: conversation.id,
        source: :staff,
        sender_email: "support@acme.com",
        body: "We can help with that.",
        delivery_status: :sent,
        lettermint_message_id: @provider_id,
        to_addresses: ["alice@customer.com"],
        cc_addresses: ["bob@customer.com"]
      )

      :ok
    end

    test "a CC bounce sends a notice that names the CC and spares the customer's copy" do
      assert {:ok, :updated, %{delivery_status: :sent}} =
               apply_event(
                 envelope("message.hard_bounced", "evt-cc", recipient_data("bob@customer.com"))
               )

      assert_email_sent(fn email ->
        assert email.subject == "Reply bounced: Billing question"
        refute email.text_body =~ "alice@customer.com"
        assert email.text_body =~ "Recipient: bob@customer.com (CC)"
        assert email.text_body =~ "customer's own copy is tracked separately"
      end)
    end

    test "each failed recipient gets one notice, however often its event is retried" do
      cc_bounce = envelope("message.hard_bounced", "evt-cc", recipient_data("bob@customer.com"))

      to_bounce =
        envelope("message.hard_bounced", "evt-to", recipient_data("alice@customer.com"))

      assert {:ok, :updated, _} = apply_event(cc_bounce)
      assert {:ok, :updated, _} = apply_event(to_bounce)
      assert {:ok, :ignored, :not_advanced} = apply_event(cc_bounce)
      assert {:ok, :ignored, :not_advanced} = apply_event(to_bounce)

      assert_email_sent(fn email -> assert email.text_body =~ "bob@customer.com (CC)" end)

      assert_email_sent(fn email ->
        assert email.text_body =~ "Recipient: alice@customer.com\n"
      end)

      assert_no_email_sent()
    end

    test "a CC bounce after the customer's own bounce is still reported" do
      apply_event(
        envelope("message.hard_bounced", "evt-to", recipient_data("alice@customer.com"))
      )

      apply_event(envelope("message.hard_bounced", "evt-cc", recipient_data("bob@customer.com")))

      assert_email_sent(fn email -> assert email.text_body =~ "Recipient: alice@customer.com" end)
      assert_email_sent(fn email -> assert email.text_body =~ "bob@customer.com (CC)" end)
    end
  end

  defp envelope(event, delivery_id, data) do
    %{
      "id" => delivery_id,
      "event" => event,
      "timestamp" => "2026-10-20T12:00:00Z",
      "data" => data
    }
  end

  defp recipient_data(recipient) do
    %{"message_id" => @provider_id, "recipient" => recipient}
  end
end
