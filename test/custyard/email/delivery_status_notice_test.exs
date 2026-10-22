defmodule Custyard.Email.DeliveryStatusNoticeTest do
  @moduledoc """
  The operator notice for a bounced or suppressed reply
  (spec-conversation-loop, "Bounce and Suppression Handling").
  """
  # async: false - turns on :email_enabled for the whole VM.
  use Custyard.DataCase, async: false

  import Custyard.Factory
  import Swoosh.TestAssertions

  alias Custyard.Email.DeliveryStatus

  @provider_id "lm-msg-notice"

  setup do
    Application.put_env(:custyard, :email_enabled, true)
    on_exit(fn -> Application.delete_env(:custyard, :email_enabled) end)
  end

  describe "operator notice" do
    setup do
      org = insert_organization(name: "Acme Corp")
      contact = insert_contact(organization_id: org.id, email: "alice@customer.com")

      conversation =
        insert_conversation(
          organization_id: org.id,
          contact_id: contact.id,
          subject: "Billing question"
        )

      insert_message(
        conversation_id: conversation.id,
        source: :operator,
        sender_email: "support@acme.com",
        body: "We can help with that.",
        delivery_status: :sent,
        lettermint_message_id: @provider_id
      )

      :ok
    end

    test "a bounce sends one notice, however often the event is retried" do
      event = envelope("message.hard_bounced", "evt-b", recipient_data("alice@customer.com"))

      assert {:ok, :updated, _} = DeliveryStatus.apply_event(event)
      assert {:ok, :ignored, :not_advanced} = DeliveryStatus.apply_event(event)

      assert_email_sent(fn email ->
        assert email.subject == "Reply bounced: Billing question"
        assert email.text_body =~ "alice@customer.com"
      end)

      assert_no_email_sent()
    end

    test "a suppression sends a notice" do
      DeliveryStatus.apply_event(
        envelope("message.suppressed", "evt-s", recipient_data("alice@customer.com"))
      )

      assert_email_sent(subject: "Reply suppressed: Billing question")
    end

    test "deliveries and failures send none" do
      DeliveryStatus.apply_event(
        envelope("message.delivered", "evt-d", recipient_data("alice@customer.com"))
      )

      DeliveryStatus.apply_event(
        envelope("message.failed", "evt-f", recipient_data("alice@customer.com"))
      )

      assert_no_email_sent()
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
