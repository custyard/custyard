defmodule Custyard.MessageTest do
  use Custyard.DataCase, async: true

  alias Custyard.Message

  import Custyard.Factory

  describe "changeset/2" do
    test "valid with required fields" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      attrs = build_message(conversation_id: conv.id)
      changeset = Message.changeset(%Message{}, attrs)

      assert changeset.valid?
    end

    test "requires source" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      attrs = build_message(conversation_id: conv.id) |> Map.delete(:source)
      changeset = Message.changeset(%Message{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).source
    end

    test "requires body" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      attrs = build_message(conversation_id: conv.id) |> Map.delete(:body)
      changeset = Message.changeset(%Message{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).body
    end

    test "requires conversation_id" do
      attrs = build_message() |> Map.delete(:conversation_id)
      changeset = Message.changeset(%Message{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).conversation_id
    end

    test "validates body max length" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      attrs = build_message(conversation_id: conv.id, body: String.duplicate("a", 100_001))
      changeset = Message.changeset(%Message{}, attrs)

      refute changeset.valid?
      assert "should be at most 100000 character(s)" in errors_on(changeset).body
    end
  end

  describe "insert_idempotent/1" do
    test "successful insert returns {:ok, message}" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      attrs = build_message(conversation_id: conv.id, message_id: "unique-msg-id-123")

      assert {:ok, message} = Message.insert_idempotent(attrs)
      assert message.id != nil
      assert message.message_id == "unique-msg-id-123"
      assert message.conversation_id == conv.id
    end

    test "duplicate message_id returns existing message" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      message_id = "duplicate-msg-id-#{System.unique_integer()}"

      # Insert the first message
      attrs = build_message(conversation_id: conv.id, message_id: message_id, body: "First body")
      {:ok, first_message} = Message.insert_idempotent(attrs)

      # Try to insert duplicate with different body
      duplicate_attrs =
        build_message(conversation_id: conv.id, message_id: message_id, body: "Second body")

      {:ok, returned_message} = Message.insert_idempotent(duplicate_attrs)

      # Should return the existing message, not create a new one
      assert returned_message.id == first_message.id
      assert returned_message.body == "First body"
    end

    test "validation errors still return {:error, changeset}" do
      # Missing required field (conversation_id)
      attrs = %{source: :email, body: "Test body", message_id: "msg-id"}

      assert {:error, changeset} = Message.insert_idempotent(attrs)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).conversation_id
    end

    test "returns {:error, changeset} for invalid source" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      attrs =
        build_message(conversation_id: conv.id)
        |> Map.put(:source, :invalid_source)

      assert {:error, changeset} = Message.insert_idempotent(attrs)
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).source
    end

    test "works without message_id (nil)" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      attrs = build_message(conversation_id: conv.id, message_id: nil)

      assert {:ok, message} = Message.insert_idempotent(attrs)
      assert message.id != nil
      assert message.message_id == nil
    end

    test "multiple messages without message_id are allowed" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      attrs1 = build_message(conversation_id: conv.id, message_id: nil, body: "Message 1")
      attrs2 = build_message(conversation_id: conv.id, message_id: nil, body: "Message 2")

      {:ok, msg1} = Message.insert_idempotent(attrs1)
      {:ok, msg2} = Message.insert_idempotent(attrs2)

      # Both should be inserted as separate messages
      assert msg1.id != msg2.id
      assert msg1.body == "Message 1"
      assert msg2.body == "Message 2"
    end
  end
end
