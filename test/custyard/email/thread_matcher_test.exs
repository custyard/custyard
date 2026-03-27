defmodule Custyard.Email.ThreadMatcherTest do
  use Custyard.DataCase, async: true

  alias Custyard.Email.ThreadMatcher

  import Custyard.Factory

  describe "find_thread/2" do
    test "thread found via In-Reply-To in same org returns {:ok, conversation}" do
      org = insert_organization()
      conversation = insert_conversation(organization_id: org.id)

      message =
        insert_message(conversation_id: conversation.id, message_id: "msg-123@example.com")

      parsed = %{
        in_reply_to: message.message_id,
        references: nil
      }

      assert {:ok, found_conversation} = ThreadMatcher.find_thread(parsed, org.id)
      assert found_conversation.id == conversation.id
    end

    test "thread found via References in same org returns {:ok, conversation}" do
      org = insert_organization()
      conversation = insert_conversation(organization_id: org.id)

      message =
        insert_message(conversation_id: conversation.id, message_id: "ref-456@example.com")

      parsed = %{
        in_reply_to: nil,
        references: "some-other-id@example.com #{message.message_id}"
      }

      assert {:ok, found_conversation} = ThreadMatcher.find_thread(parsed, org.id)
      assert found_conversation.id == conversation.id
    end

    test "In-Reply-To takes precedence over References" do
      org = insert_organization()

      conversation1 = insert_conversation(organization_id: org.id, subject: "Thread 1")

      message1 =
        insert_message(conversation_id: conversation1.id, message_id: "primary@example.com")

      conversation2 = insert_conversation(organization_id: org.id, subject: "Thread 2")

      message2 =
        insert_message(conversation_id: conversation2.id, message_id: "secondary@example.com")

      parsed = %{
        in_reply_to: message1.message_id,
        references: message2.message_id
      }

      # Should find conversation1 via In-Reply-To, not conversation2 via References
      assert {:ok, found_conversation} = ThreadMatcher.find_thread(parsed, org.id)
      assert found_conversation.id == conversation1.id
    end

    test "thread not found returns :not_found" do
      org = insert_organization()

      parsed = %{
        in_reply_to: "nonexistent@example.com",
        references: "also-nonexistent@example.com"
      }

      assert :not_found = ThreadMatcher.find_thread(parsed, org.id)
    end

    test "nil headers return :not_found" do
      org = insert_organization()

      parsed = %{
        in_reply_to: nil,
        references: nil
      }

      assert :not_found = ThreadMatcher.find_thread(parsed, org.id)
    end

    test "thread in different org not matched (prevents cross-org leakage)" do
      org1 = insert_organization()
      org2 = insert_organization()

      # Create conversation and message in org1
      conversation = insert_conversation(organization_id: org1.id)

      message =
        insert_message(conversation_id: conversation.id, message_id: "isolated@example.com")

      # Try to find it from org2's context - should NOT match
      parsed = %{
        in_reply_to: message.message_id,
        references: nil
      }

      assert :not_found = ThreadMatcher.find_thread(parsed, org2.id)

      # Verify it DOES match when searched from org1
      assert {:ok, found} = ThreadMatcher.find_thread(parsed, org1.id)
      assert found.id == conversation.id
    end

    test "cross-org References header doesn't leak conversations" do
      org1 = insert_organization()
      org2 = insert_organization()

      # Simulate a forwarded email scenario where References contains
      # message IDs from both organizations
      conv1 = insert_conversation(organization_id: org1.id)
      msg1 = insert_message(conversation_id: conv1.id, message_id: "org1-msg@example.com")

      conv2 = insert_conversation(organization_id: org2.id)
      msg2 = insert_message(conversation_id: conv2.id, message_id: "org2-msg@example.com")

      # References header that mentions both orgs' messages
      # (could happen with mailing list cross-posts or forwards)
      parsed = %{
        in_reply_to: nil,
        references: "#{msg1.message_id} #{msg2.message_id}"
      }

      # Searching from org1's context should only find org1's conversation
      assert {:ok, found1} = ThreadMatcher.find_thread(parsed, org1.id)
      assert found1.id == conv1.id

      # Searching from org2's context should only find org2's conversation
      assert {:ok, found2} = ThreadMatcher.find_thread(parsed, org2.id)
      assert found2.id == conv2.id
    end

    test "multiple References matched returns one conversation" do
      org = insert_organization()
      conversation = insert_conversation(organization_id: org.id)

      # Same conversation has multiple messages
      msg1 = insert_message(conversation_id: conversation.id, message_id: "thread-1@example.com")
      msg2 = insert_message(conversation_id: conversation.id, message_id: "thread-2@example.com")

      parsed = %{
        in_reply_to: nil,
        references: "#{msg1.message_id} #{msg2.message_id}"
      }

      assert {:ok, found} = ThreadMatcher.find_thread(parsed, org.id)
      assert found.id == conversation.id
    end
  end
end
