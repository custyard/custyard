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

    test "accepts delivery_status in cast" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      attrs = build_message(conversation_id: conv.id, delivery_status: :pending)
      changeset = Message.changeset(%Message{}, attrs)

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :delivery_status) == :pending
    end

    test "delivery_status defaults to nil for inbound messages" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      attrs = build_message(conversation_id: conv.id)
      changeset = Message.changeset(%Message{}, attrs)

      assert changeset.valid?
      assert Ecto.Changeset.get_field(changeset, :delivery_status) == nil
    end

    test "rejects invalid delivery_status" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      attrs = build_message(conversation_id: conv.id, delivery_status: :invalid_status)
      changeset = Message.changeset(%Message{}, attrs)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).delivery_status
    end
  end

  describe "delivery_status_changeset/2" do
    test "sets a valid delivery status" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      message = insert_message(conversation_id: conv.id, delivery_status: :pending)

      for status <- [:sent, :failed, :bounced] do
        changeset = Message.delivery_status_changeset(message, status)
        assert changeset.valid?, "expected #{status} to be valid"
        assert Ecto.Changeset.get_change(changeset, :delivery_status) == status
      end
    end

    test "rejects invalid delivery status" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      message = insert_message(conversation_id: conv.id, delivery_status: :pending)

      changeset = Message.delivery_status_changeset(message, :invalid)
      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).delivery_status
    end

    test "requires delivery_status" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      message = insert_message(conversation_id: conv.id)

      changeset = Message.delivery_status_changeset(message, nil)
      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).delivery_status
    end
  end

  describe "delivery_statuses/0" do
    test "returns expected list" do
      assert Message.delivery_statuses() == [:pending, :sent, :failed, :bounced, :withheld]
    end

    test "delivery_status_changeset accepts :withheld" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      message = insert_message(conversation_id: conv.id, delivery_status: :pending)

      changeset = Message.delivery_status_changeset(message, :withheld)
      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :delivery_status) == :withheld
    end
  end

  describe "lettermint_message_id field" do
    test "changeset accepts lettermint_message_id" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      attrs = build_message(conversation_id: conv.id, lettermint_message_id: "lm-12345")
      changeset = Message.changeset(%Message{}, attrs)

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :lettermint_message_id) == "lm-12345"
    end

    test "lettermint_message_id is stored and retrievable" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      message = insert_message(conversation_id: conv.id, lettermint_message_id: "lm-persist-test")

      reloaded = Custyard.Repo.get!(Message, message.id)
      assert reloaded.lettermint_message_id == "lm-persist-test"
    end

    test "lettermint_message_id defaults to nil" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      message = insert_message(conversation_id: conv.id)

      assert message.lettermint_message_id == nil
    end

    test "insert_idempotent/1 works with lettermint_message_id set" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      attrs =
        build_message(
          conversation_id: conv.id,
          message_id: "unique-lm-test-#{System.unique_integer()}",
          lettermint_message_id: "lm-idempotent-test"
        )

      assert {:ok, message} = Message.insert_idempotent(attrs)
      assert message.lettermint_message_id == "lm-idempotent-test"
    end
  end

  describe "updated_at behavior" do
    test "updated_at is set on insert" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      message = insert_message(conversation_id: conv.id)

      assert message.updated_at != nil
      assert message.inserted_at != nil
      # On insert, updated_at should equal inserted_at (or be very close)
      assert DateTime.diff(message.updated_at, message.inserted_at, :second) == 0
    end

    test "updated_at changes when delivery_status is updated" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      message = insert_message(conversation_id: conv.id, delivery_status: :pending)

      original_updated_at = message.updated_at

      # Small delay to ensure timestamp differs
      Process.sleep(1100)

      {:ok, updated} =
        message
        |> Message.delivery_status_changeset(:sent)
        |> Repo.update()

      assert updated.delivery_status == :sent
      assert DateTime.compare(updated.updated_at, original_updated_at) == :gt
    end

    test "updated_at is persisted in the database" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      message = insert_message(conversation_id: conv.id)

      reloaded = Repo.get!(Message, message.id)
      assert reloaded.updated_at != nil
      assert reloaded.updated_at == message.updated_at
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

  describe "prospect source and public_intake origin" do
    test "accepts source :prospect with origin :public_intake" do
      conv = insert_conversation(source: :public_intake)

      attrs =
        build_message(
          conversation_id: conv.id,
          source: :prospect,
          origin: :public_intake,
          sender_email: nil,
          message_id: nil,
          delivery_status: nil
        )

      changeset = Message.changeset(%Message{}, attrs)
      assert changeset.valid?

      {:ok, message} = Repo.insert(changeset)
      assert message.source == :prospect
      assert message.origin == :public_intake
      assert message.delivery_status == nil
      assert message.sender_email == nil
    end

    test "sources/0 and origins/0 include the new values" do
      assert :prospect in Message.sources()
      assert :public_intake in Message.origins()
    end
  end
end
