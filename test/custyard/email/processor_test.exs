defmodule Custyard.Email.ProcessorTest do
  use Custyard.DataCase, async: true

  alias Custyard.Conversations
  alias Custyard.Email.Processor

  import Custyard.Factory

  describe "process/1" do
    test "creates new conversation from email" do
      org = insert_organization(domain: "acme.example.com")
      _contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")

      params = %{
        "from" => "alice@acme.example.com",
        "to" => "support@custyard.test",
        "subject" => "Need help with setup",
        "text" => "Hello, I need assistance."
      }

      assert {:ok, conversation} = Processor.process(params)

      assert conversation.subject == "Need help with setup"
      assert conversation.state == :new
      assert conversation.organization_id == org.id
    end

    test "creates message for the conversation" do
      org = insert_organization(domain: "acme.example.com")
      _contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")

      params = %{
        "from" => "alice@acme.example.com",
        "subject" => "Test subject",
        "text" => "Test body"
      }

      assert {:ok, conversation} = Processor.process(params)

      messages = Conversations.list_public_messages(conversation.id)
      assert length(messages) == 1

      [message] = messages
      assert message.body == "Test body"
      assert message.source == :email
      assert message.sender_email == "alice@acme.example.com"
    end

    test "threads reply to existing conversation" do
      org = insert_organization(domain: "acme.example.com")
      contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")
      existing = insert_conversation(organization_id: org.id, contact_id: contact.id)
      insert_message(conversation_id: existing.id, message_id: "original@example.com")

      params = %{
        "from" => "alice@acme.example.com",
        "subject" => "Re: Original subject",
        "text" => "This is a reply",
        "headers" => %{
          "in-reply-to" => "original@example.com"
        }
      }

      assert {:ok, conversation} = Processor.process(params)

      # Should thread to existing conversation
      assert conversation.id == existing.id

      messages = Conversations.list_public_messages(conversation.id)
      assert length(messages) == 2
    end

    test "reactivates dormant conversation on new message" do
      org = insert_organization(domain: "acme.example.com")
      contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")

      existing =
        insert_conversation(organization_id: org.id, contact_id: contact.id, state: :dormant)

      insert_message(conversation_id: existing.id, message_id: "original@example.com")

      params = %{
        "from" => "alice@acme.example.com",
        "subject" => "Re: follow up",
        "text" => "Checking in",
        "headers" => %{
          "in-reply-to" => "original@example.com"
        }
      }

      assert {:ok, conversation} = Processor.process(params)

      assert conversation.id == existing.id
      assert conversation.state == :active
    end

    test "detects urgent keywords" do
      org = insert_organization(domain: "acme.example.com")
      _contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")

      params = %{
        "from" => "alice@acme.example.com",
        "subject" => "URGENT: System is down",
        "text" => "The production server is not responding."
      }

      assert {:ok, conversation} = Processor.process(params)

      assert conversation.urgency == :urgent
    end

    test "detects elevated priority keywords" do
      org = insert_organization(domain: "acme.example.com")
      _contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")

      params = %{
        "from" => "alice@acme.example.com",
        "subject" => "Important: License renewal",
        "text" => "Please handle ASAP."
      }

      assert {:ok, conversation} = Processor.process(params)

      assert conversation.urgency == :elevated
    end

    test "defaults to normal urgency" do
      org = insert_organization(domain: "acme.example.com")
      _contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")

      params = %{
        "from" => "alice@acme.example.com",
        "subject" => "Question about feature",
        "text" => "How do I configure X?"
      }

      assert {:ok, conversation} = Processor.process(params)

      assert conversation.urgency == :normal
    end

    test "creates organization for unknown sender domain" do
      params = %{
        "from" => "newuser@unknown-domain.test",
        "subject" => "First contact",
        "text" => "Hello"
      }

      assert {:ok, conversation} = Processor.process(params)

      # Should have created an unmatched org
      assert conversation.organization_id != nil
    end

    test "handles missing subject gracefully" do
      org = insert_organization(domain: "acme.example.com")
      _contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")

      params = %{
        "from" => "alice@acme.example.com",
        "text" => "Body without subject"
      }

      assert {:ok, conversation} = Processor.process(params)

      assert conversation.subject == "(no subject)"
    end

    test "strips HTML when no text body" do
      org = insert_organization(domain: "acme.example.com")
      _contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")

      params = %{
        "from" => "alice@acme.example.com",
        "subject" => "HTML email",
        "html" => "<html><body><p>Hello <strong>world</strong></p></body></html>"
      }

      assert {:ok, conversation} = Processor.process(params)

      messages = Conversations.list_public_messages(conversation.id)
      [message] = messages

      # HTML stripped to plain text
      assert message.body =~ "Hello"
      assert message.body =~ "world"
      refute message.body =~ "<"
    end

    test "calculates and caches score" do
      org = insert_organization(domain: "acme.example.com", tier: :enterprise)
      _contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")

      params = %{
        "from" => "alice@acme.example.com",
        "subject" => "Test",
        "text" => "Body"
      }

      assert {:ok, conversation} = Processor.process(params)

      # Score should be calculated (new state = 30, enterprise tier = 20)
      assert conversation.cached_score > 0
    end

    test "handles hyphenated headers with various cases" do
      org = insert_organization(domain: "acme.example.com")
      contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")
      existing = insert_conversation(organization_id: org.id, contact_id: contact.id)
      insert_message(conversation_id: existing.id, message_id: "original@example.com")

      # Test with "In-Reply-To" (capitalized each word) instead of "in-reply-to"
      params = %{
        "from" => "alice@acme.example.com",
        "subject" => "Re: Original subject",
        "text" => "This is a reply",
        "headers" => %{
          "In-Reply-To" => "original@example.com",
          "Message-Id" => "reply@example.com"
        }
      }

      assert {:ok, conversation} = Processor.process(params)

      # Should thread to existing conversation using case-insensitive header lookup
      assert conversation.id == existing.id
    end

    test "handles all-uppercase header names" do
      org = insert_organization(domain: "acme.example.com")
      contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")
      existing = insert_conversation(organization_id: org.id, contact_id: contact.id)
      insert_message(conversation_id: existing.id, message_id: "original@example.com")

      # Some email servers/relays may uppercase header names
      params = %{
        "from" => "alice@acme.example.com",
        "subject" => "Re: Original subject",
        "text" => "This is a reply",
        "headers" => %{
          "IN-REPLY-TO" => "original@example.com",
          "MESSAGE-ID" => "reply@example.com"
        }
      }

      assert {:ok, conversation} = Processor.process(params)
      assert conversation.id == existing.id
    end

    test "prefers exact header name match when available" do
      org = insert_organization(domain: "acme.example.com")
      contact = insert_contact(organization_id: org.id, email: "alice@acme.example.com")
      existing = insert_conversation(organization_id: org.id, contact_id: contact.id)
      insert_message(conversation_id: existing.id, message_id: "correct@example.com")

      # If both exact and differently-cased headers exist, exact match should win
      # (This tests the get_header implementation detail)
      params = %{
        "from" => "alice@acme.example.com",
        "subject" => "Re: Original subject",
        "text" => "This is a reply",
        "headers" => %{
          "in-reply-to" => "correct@example.com",
          "In-Reply-To" => "wrong@example.com"
        }
      }

      assert {:ok, conversation} = Processor.process(params)
      # Should find the thread because we matched "in-reply-to" exactly
      assert conversation.id == existing.id
    end
  end
end
