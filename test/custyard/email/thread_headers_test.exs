defmodule Custyard.Email.ThreadHeadersTest do
  use Custyard.DataCase, async: false

  import Custyard.Factory

  alias Custyard.Email.ThreadHeaders

  setup do
    org = insert_organization()
    contact = insert_contact(organization_id: org.id)

    thread =
      insert_thread(
        organization_id: org.id,
        contact_id: contact.id,
        subject: "Threading test"
      )

    {:ok, thread: thread}
  end

  describe "for_thread/1" do
    test "returns empty map when thread has no messages", %{thread: conv} do
      assert ThreadHeaders.for_thread(conv.id) == %{}
    end

    test "returns empty map when messages have nil message_ids", %{thread: conv} do
      # Portal messages may not have message_id
      insert_message(thread_id: conv.id, source: :portal, message_id: nil)
      insert_message(thread_id: conv.id, source: :staff, message_id: nil)

      assert ThreadHeaders.for_thread(conv.id) == %{}
    end

    test "returns In-Reply-To pointing to the last message_id", %{thread: conv} do
      insert_message(
        thread_id: conv.id,
        source: :email,
        message_id: "<first@example.com>"
      )

      insert_message(
        thread_id: conv.id,
        source: :email,
        message_id: "<second@example.com>"
      )

      headers = ThreadHeaders.for_thread(conv.id)

      assert headers["In-Reply-To"] == "<second@example.com>"
    end

    test "returns References with all message_ids space-separated in chronological order", %{
      thread: conv
    } do
      insert_message(
        thread_id: conv.id,
        source: :email,
        message_id: "<msg1@example.com>"
      )

      insert_message(
        thread_id: conv.id,
        source: :staff,
        message_id: "<msg2@custyard.local>"
      )

      insert_message(
        thread_id: conv.id,
        source: :email,
        message_id: "<msg3@example.com>"
      )

      headers = ThreadHeaders.for_thread(conv.id)

      assert headers["References"] ==
               "<msg1@example.com> <msg2@custyard.local> <msg3@example.com>"
    end

    test "ignores messages with nil message_id in the chain", %{thread: conv} do
      insert_message(
        thread_id: conv.id,
        source: :email,
        message_id: "<has-id@example.com>"
      )

      # Portal message without message_id
      insert_message(thread_id: conv.id, source: :portal, message_id: nil)

      insert_message(
        thread_id: conv.id,
        source: :staff,
        message_id: "<reply@custyard.local>"
      )

      headers = ThreadHeaders.for_thread(conv.id)

      assert headers["In-Reply-To"] == "<reply@custyard.local>"
      assert headers["References"] == "<has-id@example.com> <reply@custyard.local>"
    end

    test "works with a single message", %{thread: conv} do
      insert_message(
        thread_id: conv.id,
        source: :email,
        message_id: "<only@example.com>"
      )

      headers = ThreadHeaders.for_thread(conv.id)

      assert headers["In-Reply-To"] == "<only@example.com>"
      assert headers["References"] == "<only@example.com>"
    end

    test "excludes the given message id from the chain", %{thread: conv} do
      insert_message(
        thread_id: conv.id,
        source: :email,
        message_id: "<parent@example.com>"
      )

      insert_message(
        thread_id: conv.id,
        source: :staff,
        message_id: "<reply@custyard.local>"
      )

      headers =
        ThreadHeaders.for_thread(conv.id, exclude_message_id: "<reply@custyard.local>")

      assert headers["In-Reply-To"] == "<parent@example.com>"
      assert headers["References"] == "<parent@example.com>"
    end

    test "skips synthetic non-RFC message ids", %{thread: conv} do
      insert_message(
        thread_id: conv.id,
        source: :email,
        message_id: "zendesk-123@zendesk.webhook"
      )

      insert_message(
        thread_id: conv.id,
        source: :email,
        message_id: "<real@example.com>"
      )

      headers = ThreadHeaders.for_thread(conv.id)

      assert headers["In-Reply-To"] == "<real@example.com>"
      assert headers["References"] == "<real@example.com>"
    end

    test "returns empty map when only synthetic ids exist", %{thread: conv} do
      insert_message(
        thread_id: conv.id,
        source: :email,
        message_id: "slack-C1-1712.34@slack.webhook"
      )

      assert ThreadHeaders.for_thread(conv.id) == %{}
    end
  end

  describe "normalize_msg_id/1" do
    test "accepts bracketed msg-ids" do
      assert ThreadHeaders.normalize_msg_id("<abc@example.com>") == "<abc@example.com>"
    end

    test "trims surrounding whitespace" do
      assert ThreadHeaders.normalize_msg_id("  <abc@example.com> ") == "<abc@example.com>"
    end

    test "rejects values that are not RFC 5322 msg-ids" do
      assert ThreadHeaders.normalize_msg_id("zendesk-123@zendesk.webhook") == nil
      assert ThreadHeaders.normalize_msg_id("<evil@x>\r\nX-Injected: 1") == nil
      assert ThreadHeaders.normalize_msg_id("<no-at-sign>") == nil
      assert ThreadHeaders.normalize_msg_id("") == nil
      assert ThreadHeaders.normalize_msg_id(nil) == nil
    end
  end

  describe "apply_to_email/2" do
    test "applies threading headers to a Swoosh email", %{thread: conv} do
      insert_message(
        thread_id: conv.id,
        source: :email,
        message_id: "<thread@example.com>"
      )

      email = Swoosh.Email.new()
      result = ThreadHeaders.apply_to_email(email, conv.id)

      headers = Map.new(result.headers)
      assert headers["In-Reply-To"] == "<thread@example.com>"
      assert headers["References"] == "<thread@example.com>"
    end

    test "returns email unchanged when no threading headers available", %{thread: conv} do
      email = Swoosh.Email.new() |> Swoosh.Email.subject("Test")
      result = ThreadHeaders.apply_to_email(email, conv.id)

      assert result.headers == %{}
      assert result.subject == "Test"
    end
  end
end
