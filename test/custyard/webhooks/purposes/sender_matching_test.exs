defmodule Custyard.Webhooks.Purposes.SenderMatchingTest do
  use Custyard.DataCase, async: true

  alias Custyard.Webhooks.Purposes.SenderMatching
  alias Custyard.{Message, Repo}

  import Custyard.Factory

  describe "process/2" do
    test "creates new conversation and message for new sender" do
      org = insert_organization(domain: "acme.example.com")

      normalized = %{
        from: "alice@acme.example.com",
        subject: "Help needed",
        body: "I need assistance with my account",
        message_id: "msg-123@example.com",
        in_reply_to: nil,
        references: nil,
        headers: %{},
        source: :email
      }

      route_context = %{organization_id: org.id, project_id: nil}

      assert {:ok, conversation} = SenderMatching.process(normalized, route_context)
      assert conversation.organization_id == org.id
      assert conversation.subject == "Help needed"
      assert conversation.state == :new

      # Verify message was created
      messages = Repo.all(Message)
      assert length(messages) == 1
      [message] = messages
      assert message.conversation_id == conversation.id
      assert message.body == "I need assistance with my account"
      assert message.source == :email
    end

    test "threads reply to existing conversation" do
      org = insert_organization(domain: "acme.example.com")
      contact = insert_contact(organization_id: org.id, email: "bob@acme.example.com")

      existing_conv = insert_conversation(organization_id: org.id, contact_id: contact.id)

      existing_msg =
        insert_message(conversation_id: existing_conv.id, message_id: "orig-msg@example.com")

      normalized = %{
        from: "bob@acme.example.com",
        subject: "Re: Original subject",
        body: "Follow up message",
        message_id: "reply-456@example.com",
        in_reply_to: existing_msg.message_id,
        references: nil,
        headers: %{},
        source: :email
      }

      route_context = %{organization_id: org.id, project_id: nil}

      assert {:ok, conversation} = SenderMatching.process(normalized, route_context)
      # Should return the existing conversation, not create a new one
      assert conversation.id == existing_conv.id

      # Should now have 2 messages on the conversation
      messages = Message |> Ecto.Query.where(conversation_id: ^existing_conv.id) |> Repo.all()
      assert length(messages) == 2
    end

    test "returns existing conversation for duplicate message_id (idempotency)" do
      org = insert_organization(domain: "acme.example.com")

      # Create existing conversation with a message
      existing_conv = insert_conversation(organization_id: org.id, subject: "Original")

      _existing_msg =
        insert_message(conversation_id: existing_conv.id, message_id: "dup-msg@example.com")

      # Try to process the same message_id again
      normalized = %{
        from: "alice@acme.example.com",
        subject: "Duplicate attempt",
        body: "This is a retry of the same message",
        message_id: "dup-msg@example.com",
        in_reply_to: nil,
        references: nil,
        headers: %{},
        source: :email
      }

      route_context = %{organization_id: org.id, project_id: nil}

      assert {:ok, conversation} = SenderMatching.process(normalized, route_context)
      # Should return existing conversation, not create duplicate
      assert conversation.id == existing_conv.id

      # Should not have created an additional message
      messages = Message |> Ecto.Query.where(message_id: "dup-msg@example.com") |> Repo.all()
      assert length(messages) == 1
    end

    test "the same provider message ID is retained separately for two organizations" do
      first_org = insert_organization(domain: "first.example.com")
      second_org = insert_organization(domain: "second.example.com")

      normalized = %{
        from: "sender@example.com",
        subject: "Shared delivery",
        body: "Same message delivered to two customers",
        message_id: "shared-delivery@example.com",
        in_reply_to: nil,
        references: nil,
        headers: %{},
        source: :lettermint
      }

      assert {:ok, first} = SenderMatching.process(normalized, %{organization_id: first_org.id})
      assert {:ok, second} = SenderMatching.process(normalized, %{organization_id: second_org.id})
      assert first.id != second.id
      assert second.organization_id == second_org.id

      messages =
        Message |> Ecto.Query.where(message_id: "shared-delivery@example.com") |> Repo.all()

      assert length(messages) == 2

      assert MapSet.new(Enum.map(messages, & &1.conversation_id)) ==
               MapSet.new([first.id, second.id])
    end

    test "Zendesk comments thread by ticket and deduplicate by comment within a route" do
      alias Custyard.Webhooks.Adapters.Zendesk

      org = insert_organization(domain: "zendesk.example.com")
      route_context = %{organization_id: org.id, route_id: 42}

      ticket = %{
        "id" => 987,
        "subject" => "Help",
        "requester" => %{"email" => "alice@example.com"}
      }

      {:ok, first_event} =
        Zendesk.normalize(%{
          "ticket" => Map.put(ticket, "comment", %{"id" => 10, "body" => "First"})
        })

      {:ok, second_event} =
        Zendesk.normalize(%{
          "ticket" => Map.put(ticket, "comment", %{"id" => 11, "body" => "Second"})
        })

      assert {:ok, first} = SenderMatching.process(first_event, route_context)
      assert {:ok, second} = SenderMatching.process(second_event, route_context)
      assert first.id == second.id
      assert {:ok, retry} = SenderMatching.process(second_event, route_context)
      assert retry.id == first.id

      messages = Message |> Ecto.Query.where(conversation_id: ^first.id) |> Repo.all()
      assert Enum.sort(Enum.map(messages, & &1.body)) == ["First", "Second"]
    end

    test "identical Zendesk ticket and comment IDs on separate routes stay separate" do
      alias Custyard.Webhooks.Adapters.Zendesk

      org = insert_organization(domain: "zendesk-routes.example.com")

      ticket = %{
        "id" => 100,
        "subject" => "Same remote ID",
        "requester" => %{"email" => "alice@example.com"},
        "comment" => %{"id" => 1, "body" => "Route-specific"}
      }

      {:ok, event} = Zendesk.normalize(%{"ticket" => ticket})
      assert {:ok, first} = SenderMatching.process(event, %{organization_id: org.id, route_id: 1})

      assert {:ok, second} =
               SenderMatching.process(event, %{organization_id: org.id, route_id: 2})

      assert first.id != second.id
    end

    test "detects urgent subject keywords" do
      org = insert_organization(domain: "acme.example.com")

      normalized = %{
        from: "alice@acme.example.com",
        subject: "URGENT: Site is down",
        body: "Please help immediately",
        message_id: "urgent-1@example.com",
        in_reply_to: nil,
        references: nil,
        headers: %{},
        source: :email
      }

      route_context = %{organization_id: org.id, project_id: nil}

      assert {:ok, conversation} = SenderMatching.process(normalized, route_context)
      assert conversation.urgency == :urgent
    end

    test "detects elevated subject keywords" do
      org = insert_organization(domain: "acme.example.com")

      normalized = %{
        from: "alice@acme.example.com",
        subject: "Important request",
        body: "Please prioritize this",
        message_id: "elevated-1@example.com",
        in_reply_to: nil,
        references: nil,
        headers: %{},
        source: :email
      }

      route_context = %{organization_id: org.id, project_id: nil}

      assert {:ok, conversation} = SenderMatching.process(normalized, route_context)
      assert conversation.urgency == :elevated
    end

    test "reactivates dormant conversation on new message" do
      org = insert_organization(domain: "acme.example.com")

      # Create dormant conversation
      dormant_conv =
        insert_conversation(
          organization_id: org.id,
          state: :dormant,
          subject: "Old issue"
        )

      existing_msg =
        insert_message(conversation_id: dormant_conv.id, message_id: "old-msg@example.com")

      # Reply to dormant conversation
      normalized = %{
        from: "alice@acme.example.com",
        subject: "Re: Old issue",
        body: "Actually, I still need help",
        message_id: "reopen-1@example.com",
        in_reply_to: existing_msg.message_id,
        references: nil,
        headers: %{},
        source: :email
      }

      route_context = %{organization_id: org.id, project_id: nil}

      assert {:ok, conversation} = SenderMatching.process(normalized, route_context)
      assert conversation.id == dormant_conv.id
      # Should be reactivated
      assert conversation.state == :active
    end

    test "assigns project_id from route context" do
      org = insert_organization(domain: "acme.example.com")
      project = insert_project(organization_id: org.id)

      normalized = %{
        from: "alice@acme.example.com",
        subject: "Project question",
        body: "Question about the project",
        message_id: "proj-1@example.com",
        in_reply_to: nil,
        references: nil,
        headers: %{},
        source: :email
      }

      route_context = %{organization_id: org.id, project_id: project.id}

      assert {:ok, conversation} = SenderMatching.process(normalized, route_context)
      assert conversation.project_id == project.id
    end

    test "falls back to domain matching without route context" do
      org = insert_organization(domain: "acme.example.com")

      normalized = %{
        from: "alice@acme.example.com",
        subject: "No route context",
        body: "Testing domain matching",
        message_id: "domain-1@example.com",
        in_reply_to: nil,
        references: nil,
        headers: %{},
        source: :email
      }

      # Empty route context triggers domain-based matching
      assert {:ok, conversation} = SenderMatching.process(normalized, %{})
      assert conversation.organization_id == org.id
    end
  end

  describe "chat providers and blank payloads" do
    alias Custyard.Webhooks.Adapters.{Intercom, Slack}

    test "a Slack event creates a conversation with no contact" do
      org = insert_organization(domain: "slack.example.com")
      route_context = %{organization_id: org.id, route_id: 7}

      {:ok, event} =
        Slack.normalize(%{
          "team_id" => "T1",
          "event" => %{
            "type" => "message",
            "user" => "U12345",
            "channel" => "C1",
            "ts" => "1700000000.000100",
            "text" => "hello from slack"
          }
        })

      assert {:ok, conversation} = SenderMatching.process(event, route_context)
      assert conversation.organization_id == org.id
      assert conversation.contact_id == nil
      assert conversation.source == :slack

      [message] = Message |> Ecto.Query.where(conversation_id: ^conversation.id) |> Repo.all()
      assert message.sender_email == "U12345"
      assert message.body == "hello from slack"
    end

    test "Intercom replies thread together when the root event was never stored" do
      org = insert_organization(domain: "intercom.example.com")
      route_context = %{organization_id: org.id, route_id: 8}

      reply = fn part_id, body ->
        {:ok, event} =
          Intercom.normalize(%{
            "topic" => "conversation.user.replied",
            "data" => %{
              "item" => %{
                "id" => "555",
                "source" => %{
                  "subject" => "Hi",
                  "author" => %{"email" => "alice@example.com", "name" => "Alice"}
                },
                "conversation_parts" => %{
                  "conversation_parts" => [
                    %{
                      "id" => part_id,
                      "body" => body,
                      "author" => %{"email" => "alice@example.com", "type" => "user"}
                    }
                  ]
                }
              }
            }
          })

        event
      end

      assert {:ok, first} = SenderMatching.process(reply.("p1", "First"), route_context)
      assert {:ok, second} = SenderMatching.process(reply.("p2", "Second"), route_context)
      assert second.id == first.id

      messages = Message |> Ecto.Query.where(conversation_id: ^first.id) |> Repo.all()
      assert Enum.sort(Enum.map(messages, & &1.body)) == ["First", "Second"]
    end

    test "blank subject and body are stored with placeholders instead of rejecting the message" do
      org = insert_organization(domain: "blank.example.com")

      normalized = %{
        from: "alice@blank.example.com",
        subject: "",
        body: "   ",
        message_id: "blank-1@example.com",
        in_reply_to: nil,
        references: nil,
        headers: %{},
        source: :email
      }

      assert {:ok, conversation} =
               SenderMatching.process(normalized, %{organization_id: org.id, project_id: nil})

      assert conversation.subject == "(no subject)"

      [message] = Message |> Ecto.Query.where(conversation_id: ^conversation.id) |> Repo.all()
      assert message.body == "(empty message)"
    end

    test "a missing From yields a conversation without a contact" do
      org = insert_organization(domain: "nofrom.example.com")

      normalized = %{
        from: nil,
        subject: "No sender",
        body: "body",
        message_id: "nofrom-1@example.com",
        in_reply_to: nil,
        references: nil,
        headers: %{},
        source: :email
      }

      assert {:ok, conversation} =
               SenderMatching.process(normalized, %{organization_id: org.id, project_id: nil})

      assert conversation.contact_id == nil
    end
  end

  describe "customer replies to waiting conversations" do
    test "an inbound email reactivates a conversation waiting on the customer" do
      org = insert_organization(domain: "acme.example.com")
      waiting = insert_conversation(organization_id: org.id, state: :waiting, subject: "Pending")
      existing = insert_message(conversation_id: waiting.id, message_id: "waiting-1@example.com")

      normalized = %{
        from: "alice@acme.example.com",
        subject: "Re: Pending",
        body: "Here is the information you asked for",
        message_id: "waiting-reply-1@example.com",
        in_reply_to: existing.message_id,
        references: nil,
        headers: %{},
        source: :email
      }

      assert {:ok, conversation} =
               SenderMatching.process(normalized, %{organization_id: org.id, project_id: nil})

      assert conversation.id == waiting.id
      assert conversation.state == :active
    end
  end
end
