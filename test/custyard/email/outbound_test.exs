defmodule Custyard.Email.OutboundTest do
  use Custyard.DataCase, async: false

  import Custyard.Factory
  import Swoosh.TestAssertions

  alias Custyard.Email.Outbound
  alias Custyard.{Message, Repo}

  setup do
    org = insert_organization(name: "Acme Support")
    contact = insert_contact(organization_id: org.id, name: "Alice", email: "alice@customer.com")

    conversation =
      insert_conversation(
        organization_id: org.id,
        contact_id: contact.id,
        subject: "Help with billing"
      )
      |> Repo.preload([:organization, :contact])

    # Insert an inbound customer message to thread against
    customer_msg =
      insert_message(
        conversation_id: conversation.id,
        source: :email,
        sender_email: "alice@customer.com",
        message_id: "<abc123@customer.com>",
        body: "I need help with my bill"
      )

    # Insert an operator reply message (pending delivery)
    operator_msg =
      insert_message(
        conversation_id: conversation.id,
        source: :operator,
        sender_email: "support@acme.com",
        message_id: "<reply-001@custyard.local>",
        in_reply_to: "<abc123@customer.com>",
        body: "We can help with that.",
        delivery_status: :pending
      )

    {:ok,
     org: org,
     contact: contact,
     conversation: conversation,
     customer_msg: customer_msg,
     operator_msg: operator_msg}
  end

  describe "deliver/1" do
    test "delivers email and marks status as :sent", %{operator_msg: msg} do
      assert {:ok, updated} = Outbound.deliver(msg)
      assert updated.delivery_status == :sent

      # Verify persisted in DB
      reloaded = Repo.get!(Message, msg.id)
      assert reloaded.delivery_status == :sent
    end

    test "sends email to the contact's address", %{operator_msg: msg} do
      {:ok, _} = Outbound.deliver(msg)

      assert_email_sent(fn email ->
        assert email.to == [{"", "alice@customer.com"}]
      end)
    end

    test "sets from address using sender_email and org name", %{operator_msg: msg} do
      {:ok, _} = Outbound.deliver(msg)

      assert_email_sent(fn email ->
        assert email.from == {"Acme Support", "support@acme.com"}
      end)
    end

    test "sets subject with Re: prefix", %{operator_msg: msg} do
      {:ok, _} = Outbound.deliver(msg)

      assert_email_sent(fn email ->
        assert email.subject == "Re: Help with billing"
      end)
    end

    test "includes text and html body", %{operator_msg: msg} do
      {:ok, _} = Outbound.deliver(msg)

      assert_email_sent(fn email ->
        assert email.text_body == "We can help with that."
        assert email.html_body =~ "We can help with that."
        assert email.html_body =~ "<html>"
      end)
    end

    test "includes threading headers when in_reply_to is set", %{operator_msg: msg} do
      {:ok, _} = Outbound.deliver(msg)

      assert_email_sent(fn email ->
        headers = Map.new(email.headers)
        assert headers["In-Reply-To"] == "<abc123@customer.com>"
        assert headers["References"] == "<abc123@customer.com>"
        assert headers["Message-ID"] == "<reply-001@custyard.local>"
      end)
    end

    test "marks status as :failed when conversation has no contact", %{conversation: conv} do
      # Create a conversation without a contact (e.g., disambiguation)
      no_contact_conv =
        insert_conversation(organization_id: conv.organization_id, contact_id: nil)

      msg =
        insert_message(
          conversation_id: no_contact_conv.id,
          source: :operator,
          body: "Test reply",
          delivery_status: :pending
        )

      assert {:error, :no_recipient_email, updated} = Outbound.deliver(msg)
      assert updated.delivery_status == :failed
    end

    test "uses fallback from address when sender_email is nil", %{conversation: conv} do
      msg =
        insert_message(
          conversation_id: conv.id,
          source: :operator,
          sender_email: nil,
          body: "Reply without sender",
          delivery_status: :pending
        )

      {:ok, _} = Outbound.deliver(msg)

      assert_email_sent(fn email ->
        {_name, from_email} = email.from
        assert from_email == "support@custyard.local"
      end)
    end
  end

  describe "compose/4" do
    test "builds email struct without delivering", %{operator_msg: msg, conversation: conv} do
      email = Outbound.compose(msg, conv, "alice@customer.com", {"Acme", "support@acme.com"})

      assert email.to == [{"", "alice@customer.com"}]
      assert email.from == {"Acme", "support@acme.com"}
      assert email.subject == "Re: Help with billing"
      assert email.text_body == "We can help with that."
      assert_no_email_sent()
    end

    test "does not add Re: prefix when already present", %{
      org: org,
      contact: contact,
      operator_msg: msg
    } do
      re_conv =
        insert_conversation(
          organization_id: org.id,
          contact_id: contact.id,
          subject: "Re: Already replied"
        )
        |> Repo.preload([:organization, :contact])

      email = Outbound.compose(msg, re_conv, "alice@customer.com", {"Acme", "support@acme.com"})

      assert email.subject == "Re: Already replied"
    end

    test "does not add Re: prefix when present with different casing", %{
      org: org,
      contact: contact,
      operator_msg: msg
    } do
      re_conv =
        insert_conversation(
          organization_id: org.id,
          contact_id: contact.id,
          subject: "RE: Invoice 42"
        )
        |> Repo.preload([:organization, :contact])

      email = Outbound.compose(msg, re_conv, "alice@customer.com", {"Acme", "support@acme.com"})

      assert email.subject == "RE: Invoice 42"
    end

    test "omits threading headers when in_reply_to is nil", %{conversation: conv} do
      msg =
        insert_message(
          conversation_id: conv.id,
          source: :operator,
          body: "First outbound message",
          in_reply_to: nil,
          message_id: "<first@custyard.local>",
          delivery_status: :pending
        )

      email = Outbound.compose(msg, conv, "alice@customer.com", {"Acme", "support@acme.com"})
      headers = Map.new(email.headers)

      refute Map.has_key?(headers, "In-Reply-To")
      refute Map.has_key?(headers, "References")
      assert headers["Message-ID"] == "<first@custyard.local>"
    end

    test "escapes HTML in body", %{conversation: conv} do
      msg =
        insert_message(
          conversation_id: conv.id,
          source: :operator,
          body: "Use <script>alert('xss')</script> safely",
          delivery_status: :pending
        )

      email = Outbound.compose(msg, conv, "alice@customer.com", {"Acme", "support@acme.com"})

      refute email.html_body =~ "<script>"
      assert email.html_body =~ "&lt;script&gt;"
    end
  end

  describe "threading headers" do
    test "References carries the full chain of prior message ids", %{org: org} do
      contact = insert_contact(organization_id: org.id, email: "chain@customer.com")

      conversation =
        insert_conversation(organization_id: org.id, contact_id: contact.id, subject: "Chain")
        |> Repo.preload([:organization, :contact])

      insert_message(
        conversation_id: conversation.id,
        source: :email,
        message_id: "<a@customer.com>",
        body: "First question"
      )

      insert_message(
        conversation_id: conversation.id,
        source: :operator,
        message_id: "<b@custyard.local>",
        in_reply_to: "<a@customer.com>",
        body: "First answer",
        delivery_status: :sent
      )

      insert_message(
        conversation_id: conversation.id,
        source: :email,
        message_id: "<c@customer.com>",
        body: "Follow-up"
      )

      reply =
        insert_message(
          conversation_id: conversation.id,
          source: :operator,
          message_id: "<d@custyard.local>",
          in_reply_to: "<c@customer.com>",
          body: "Second answer",
          delivery_status: :pending
        )

      email =
        Outbound.compose(reply, conversation, "chain@customer.com", {"Acme", "support@acme.com"})

      headers = Map.new(email.headers)
      assert headers["In-Reply-To"] == "<c@customer.com>"
      assert headers["References"] == "<a@customer.com> <b@custyard.local> <c@customer.com>"
      # A message must not reference itself
      refute headers["References"] =~ "<d@custyard.local>"
    end

    test "omits threading headers for synthetic non-RFC message ids", %{org: org} do
      contact = insert_contact(organization_id: org.id, email: "zd@customer.com")

      conversation =
        insert_conversation(organization_id: org.id, contact_id: contact.id, subject: "Zendesk")
        |> Repo.preload([:organization, :contact])

      insert_message(
        conversation_id: conversation.id,
        source: :email,
        message_id: "zendesk-123@zendesk.webhook",
        body: "Via Zendesk"
      )

      reply =
        insert_message(
          conversation_id: conversation.id,
          source: :operator,
          message_id: "<r1@custyard.local>",
          in_reply_to: "zendesk-123@zendesk.webhook",
          body: "Reply",
          delivery_status: :pending
        )

      email =
        Outbound.compose(reply, conversation, "zd@customer.com", {"Acme", "support@acme.com"})

      headers = Map.new(email.headers)
      refute Map.has_key?(headers, "In-Reply-To")
      refute Map.has_key?(headers, "References")
      assert headers["Message-ID"] == "<r1@custyard.local>"
    end

    test "neutralizes CRLF injection in subject and msg-id fields", %{org: org} do
      contact = insert_contact(organization_id: org.id, email: "victim@customer.com")

      conversation =
        insert_conversation(
          organization_id: org.id,
          contact_id: contact.id,
          subject: "Help\r\nBcc: attacker@evil.com"
        )
        |> Repo.preload([:organization, :contact])

      msg =
        insert_message(
          conversation_id: conversation.id,
          source: :operator,
          body: "Reply",
          message_id: "<ok@custyard.local>\r\nX-Injected: 1",
          in_reply_to: "<parent@customer.com>\r\nX-Injected: 2",
          delivery_status: :pending
        )

      email =
        Outbound.compose(msg, conversation, "victim@customer.com", {"Acme", "support@acme.com"})

      assert email.subject == "Re: Help Bcc: attacker@evil.com"

      headers = Map.new(email.headers)
      refute Map.has_key?(headers, "Message-ID")
      refute Map.has_key?(headers, "In-Reply-To")
      refute Map.has_key?(headers, "References")

      Enum.each(email.headers, fn {name, value} ->
        refute name =~ ~r/[\r\n]/
        refute value =~ ~r/[\r\n]/
      end)
    end
  end

  describe "from_name resolution" do
    test "uses organization name when present", %{operator_msg: msg} do
      {:ok, _} = Outbound.deliver(msg)

      assert_email_sent(fn email ->
        {from_name, _from_email} = email.from
        assert from_name == "Acme Support"
      end)
    end

    test "quotes display names containing RFC 5322 specials" do
      org = insert_organization(name: "Acme, Inc.")
      contact = insert_contact(organization_id: org.id, email: "quoted@customer.com")

      conversation =
        insert_conversation(organization_id: org.id, contact_id: contact.id, subject: "Quoting")
        |> Repo.preload([:organization, :contact])

      msg =
        insert_message(
          conversation_id: conversation.id,
          source: :operator,
          sender_email: "support@acme.com",
          body: "Reply",
          delivery_status: :pending
        )

      {:ok, _} = Outbound.deliver(msg)

      assert_email_sent(fn email ->
        assert email.from == {~s("Acme, Inc."), "support@acme.com"}
      end)
    end

    test "falls back to Custyard when organization has no name", %{conversation: conv} do
      msg =
        insert_message(
          conversation_id: conv.id,
          source: :operator,
          sender_email: "support@test.com",
          body: "Fallback name test",
          delivery_status: :pending
        )

      # Test compose directly with nil organization
      email =
        Outbound.compose(
          msg,
          %{conv | organization: nil},
          "alice@customer.com",
          {"Custyard", "support@test.com"}
        )

      assert email.from == {"Custyard", "support@test.com"}
    end
  end

  describe "delivery_status transitions" do
    test "pending -> sent on successful delivery", %{operator_msg: msg} do
      assert msg.delivery_status == :pending
      {:ok, updated} = Outbound.deliver(msg)
      assert updated.delivery_status == :sent
    end

    test "pending -> failed when delivery fails", %{conversation: conv} do
      # Create a conversation without a contact to trigger delivery failure
      no_contact_conv =
        insert_conversation(organization_id: conv.organization_id, contact_id: nil)

      msg =
        insert_message(
          conversation_id: no_contact_conv.id,
          source: :operator,
          body: "Will fail",
          delivery_status: :pending
        )

      assert {:error, _reason, updated} = Outbound.deliver(msg)
      assert updated.delivery_status == :failed

      # Confirm persisted
      reloaded = Repo.get!(Message, msg.id)
      assert reloaded.delivery_status == :failed
    end
  end
end
