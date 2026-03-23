defmodule Custyard.ConversationTest do
  use Custyard.DataCase, async: true

  alias Custyard.Conversation

  import Custyard.Factory

  describe "changeset/2" do
    test "valid with required fields" do
      org = insert_organization()
      attrs = build_conversation(organization_id: org.id)
      changeset = Conversation.changeset(%Conversation{}, attrs)

      assert changeset.valid?
    end

    test "requires subject" do
      org = insert_organization()
      attrs = build_conversation(organization_id: org.id) |> Map.delete(:subject)
      changeset = Conversation.changeset(%Conversation{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).subject
    end

    test "requires organization_id" do
      attrs = build_conversation() |> Map.delete(:organization_id)
      changeset = Conversation.changeset(%Conversation{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).organization_id
    end
  end

  describe "state enum" do
    test "accepts valid state values" do
      org = insert_organization()

      for state <- [:new, :active, :waiting, :dormant, :resolved] do
        attrs = build_conversation(organization_id: org.id, state: state)
        changeset = Conversation.changeset(%Conversation{}, attrs)

        assert changeset.valid?, "Expected state #{state} to be valid"
      end
    end

    test "rejects invalid state value" do
      org = insert_organization()
      attrs = build_conversation(organization_id: org.id, state: :closed)
      changeset = Conversation.changeset(%Conversation{}, attrs)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).state
    end

    test "defaults to new state" do
      org = insert_organization()
      attrs = build_conversation(organization_id: org.id) |> Map.delete(:state)
      {:ok, conv} = %Conversation{} |> Conversation.changeset(attrs) |> Repo.insert()

      assert conv.state == :new
    end
  end

  describe "urgency enum" do
    test "accepts valid urgency values" do
      org = insert_organization()

      for urgency <- [:normal, :elevated, :urgent] do
        attrs = build_conversation(organization_id: org.id, urgency: urgency)
        changeset = Conversation.changeset(%Conversation{}, attrs)

        assert changeset.valid?, "Expected urgency #{urgency} to be valid"
      end
    end

    test "rejects invalid urgency value" do
      org = insert_organization()
      attrs = build_conversation(organization_id: org.id, urgency: :critical)
      changeset = Conversation.changeset(%Conversation{}, attrs)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).urgency
    end

    test "defaults to normal urgency" do
      org = insert_organization()
      attrs = build_conversation(organization_id: org.id) |> Map.delete(:urgency)
      {:ok, conv} = %Conversation{} |> Conversation.changeset(attrs) |> Repo.insert()

      assert conv.urgency == :normal
    end
  end

  describe "state_changeset/2" do
    test "allows transition to valid state" do
      conv = %Conversation{state: :new}
      changeset = Conversation.state_changeset(conv, :active)

      assert changeset.valid?
      assert get_change(changeset, :state) == :active
    end

    test "allows transition through all states" do
      for state <- Conversation.states() do
        conv = %Conversation{state: :new}
        changeset = Conversation.state_changeset(conv, state)

        assert changeset.valid?, "Expected transition to #{state} to be valid"
      end
    end

    test "rejects invalid state value" do
      conv = %Conversation{state: :new}
      changeset = Conversation.state_changeset(conv, :invalid_state)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).state
    end

    test "persists state change to database" do
      conv = insert_conversation(state: :new)
      changeset = Conversation.state_changeset(conv, :active)
      {:ok, updated} = Repo.update(changeset)

      assert updated.state == :active
    end
  end

  describe "snooze_changeset/2" do
    test "sets snoozed_until timestamp" do
      conv = %Conversation{}
      until = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
      changeset = Conversation.snooze_changeset(conv, until)

      assert changeset.valid?
      assert get_change(changeset, :snoozed_until) == until
    end

    test "clears snooze with nil" do
      until = DateTime.add(DateTime.utc_now(), 3600, :second)
      conv = insert_conversation(snoozed_until: until)
      changeset = Conversation.snooze_changeset(conv, nil)
      {:ok, updated} = Repo.update(changeset)

      assert updated.snoozed_until == nil
    end
  end

  describe "helper functions" do
    test "states/0 returns all valid states" do
      assert Conversation.states() == [:new, :active, :waiting, :dormant, :resolved]
    end

    test "urgencies/0 returns all valid urgencies" do
      assert Conversation.urgencies() == [:normal, :elevated, :urgent]
    end
  end
end
