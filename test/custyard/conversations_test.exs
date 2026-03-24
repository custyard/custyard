defmodule Custyard.ConversationsTest do
  # SQLite doesn't support async tests due to database locking
  use Custyard.DataCase, async: false

  alias Custyard.Conversations

  import Custyard.Factory

  describe "list_neglected/0" do
    test "returns conversations excluding resolved" do
      org = insert_organization()
      active = insert_conversation(organization_id: org.id, state: :active)
      _resolved = insert_conversation(organization_id: org.id, state: :resolved)

      results = Conversations.list_neglected()
      ids = Enum.map(results, & &1.id)

      assert active.id in ids
      refute Enum.any?(results, &(&1.state == :resolved))
    end

    test "excludes snoozed conversations" do
      org = insert_organization()
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      _snoozed = insert_conversation(organization_id: org.id, snoozed_until: future)
      active = insert_conversation(organization_id: org.id, snoozed_until: nil)

      results = Conversations.list_neglected()
      ids = Enum.map(results, & &1.id)

      assert active.id in ids
      refute Enum.any?(results, fn c -> c.snoozed_until != nil end)
    end

    test "preloads organization and contact" do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id)
      _conv = insert_conversation(organization_id: org.id, contact_id: contact.id)

      [result] = Conversations.list_neglected()

      assert result.organization.id == org.id
      assert result.contact.id == contact.id
    end
  end

  describe "list_for_attention_queue/1" do
    test "returns conversations ordered by cached_score descending" do
      org = insert_organization()

      conv_low = insert_conversation(organization_id: org.id, cached_score: 10)
      conv_high = insert_conversation(organization_id: org.id, cached_score: 50)
      conv_mid = insert_conversation(organization_id: org.id, cached_score: 30)

      results = Conversations.list_for_attention_queue()
      ids = Enum.map(results, & &1.conversation.id)

      assert ids == [conv_high.id, conv_mid.id, conv_low.id]
    end

    test "excludes snoozed conversations" do
      org = insert_organization()
      future = DateTime.add(DateTime.utc_now(), 3600, :second)

      _snoozed = insert_conversation(organization_id: org.id, snoozed_until: future)
      active = insert_conversation(organization_id: org.id, snoozed_until: nil)

      results = Conversations.list_for_attention_queue()
      ids = Enum.map(results, & &1.conversation.id)

      assert active.id in ids
      refute Enum.any?(results, &(&1.conversation.snoozed_until != nil))
    end

    test "filters by state" do
      org = insert_organization()

      new_conv = insert_conversation(organization_id: org.id, state: :new)
      active_conv = insert_conversation(organization_id: org.id, state: :active)
      _waiting_conv = insert_conversation(organization_id: org.id, state: :waiting)

      new_results = Conversations.list_for_attention_queue(filter: "new")
      new_ids = Enum.map(new_results, & &1.conversation.id)

      assert new_conv.id in new_ids
      refute active_conv.id in new_ids
    end

    test "includes message count" do
      conv = insert_conversation()
      insert_message(conversation_id: conv.id)
      insert_message(conversation_id: conv.id)

      [result] = Conversations.list_for_attention_queue()

      assert result.message_count == 2
    end
  end

  describe "list_for_organization/2" do
    test "returns conversations for the given organization" do
      org1 = insert_organization()
      org2 = insert_organization()

      conv1 = insert_conversation(organization_id: org1.id)
      _conv2 = insert_conversation(organization_id: org2.id)

      results = Conversations.list_for_organization(org1.id)
      ids = Enum.map(results, & &1.id)

      assert ids == [conv1.id]
    end

    test "excludes resolved conversations by default" do
      org = insert_organization()

      active = insert_conversation(organization_id: org.id, state: :active)
      _resolved = insert_conversation(organization_id: org.id, state: :resolved)

      results = Conversations.list_for_organization(org.id)
      ids = Enum.map(results, & &1.id)

      assert ids == [active.id]
    end

    test "includes resolved when option set" do
      org = insert_organization()

      active = insert_conversation(organization_id: org.id, state: :active)
      resolved = insert_conversation(organization_id: org.id, state: :resolved)

      results = Conversations.list_for_organization(org.id, include_resolved: true)
      ids = Enum.map(results, & &1.id)

      assert active.id in ids
      assert resolved.id in ids
    end

    test "filters by contact_id" do
      org = insert_organization()
      contact1 = insert_contact(organization_id: org.id)
      contact2 = insert_contact(organization_id: org.id)

      conv1 = insert_conversation(organization_id: org.id, contact_id: contact1.id)
      _conv2 = insert_conversation(organization_id: org.id, contact_id: contact2.id)

      results = Conversations.list_for_organization(org.id, contact_id: contact1.id)
      ids = Enum.map(results, & &1.id)

      assert ids == [conv1.id]
    end
  end

  describe "get_conversation/1" do
    test "returns conversation when found" do
      conv = insert_conversation()

      result = Conversations.get_conversation(conv.id)

      assert result.id == conv.id
    end

    test "returns nil when not found" do
      assert Conversations.get_conversation(99999) == nil
    end
  end

  describe "get_conversation!/1" do
    test "returns conversation when found" do
      conv = insert_conversation()

      result = Conversations.get_conversation!(conv.id)

      assert result.id == conv.id
    end

    test "raises when not found" do
      assert_raise Ecto.NoResultsError, fn ->
        Conversations.get_conversation!(99999)
      end
    end
  end

  describe "get_conversation_for_organization/2" do
    test "returns conversation when org matches" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)

      assert {:ok, result} = Conversations.get_conversation_for_organization(conv.id, org.id)
      assert result.id == conv.id
    end

    test "returns error when conversation not found" do
      assert {:error, :not_found} = Conversations.get_conversation_for_organization(99999, 1)
    end

    test "returns error when org does not match" do
      org1 = insert_organization()
      org2 = insert_organization()
      conv = insert_conversation(organization_id: org1.id)

      assert {:error, :unauthorized} =
               Conversations.get_conversation_for_organization(conv.id, org2.id)
    end
  end

  describe "get_with_messages/1" do
    test "preloads messages in order" do
      conv = insert_conversation()
      msg1 = insert_message(conversation_id: conv.id)
      msg2 = insert_message(conversation_id: conv.id)

      result = Conversations.get_with_messages(conv.id)

      assert length(result.messages) == 2
      assert [first, second] = result.messages
      assert first.id == msg1.id
      assert second.id == msg2.id
    end

    test "preloads organization and contact" do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id)
      conv = insert_conversation(organization_id: org.id, contact_id: contact.id)

      result = Conversations.get_with_messages(conv.id)

      assert result.organization.id == org.id
      assert result.contact.id == contact.id
    end
  end

  describe "list_public_messages/1" do
    test "returns non-internal messages" do
      conv = insert_conversation()
      public = insert_message(conversation_id: conv.id, is_internal_note: false)
      _internal = insert_message(conversation_id: conv.id, is_internal_note: true)

      results = Conversations.list_public_messages(conv.id)
      ids = Enum.map(results, & &1.id)

      assert ids == [public.id]
    end

    test "orders messages by inserted_at ascending" do
      conv = insert_conversation()
      first = insert_message(conversation_id: conv.id, is_internal_note: false)
      second = insert_message(conversation_id: conv.id, is_internal_note: false)

      results = Conversations.list_public_messages(conv.id)
      ids = Enum.map(results, & &1.id)

      assert ids == [first.id, second.id]
    end
  end

  describe "count_messages/1" do
    test "returns count of messages" do
      conv = insert_conversation()
      insert_message(conversation_id: conv.id)
      insert_message(conversation_id: conv.id)
      insert_message(conversation_id: conv.id)

      assert Conversations.count_messages(conv.id) == 3
    end

    test "returns 0 for conversation with no messages" do
      conv = insert_conversation()

      assert Conversations.count_messages(conv.id) == 0
    end
  end

  describe "create_conversation/1" do
    test "creates a conversation with valid attributes" do
      org = insert_organization()

      assert {:ok, conv} =
               Conversations.create_conversation(%{
                 subject: "Test subject",
                 organization_id: org.id
               })

      assert conv.subject == "Test subject"
      assert conv.organization_id == org.id
      assert conv.state == :new
    end

    test "returns error for invalid attributes" do
      assert {:error, changeset} = Conversations.create_conversation(%{})
      assert %{subject: ["can't be blank"]} = errors_on(changeset)
    end
  end

  describe "create_message/1" do
    test "creates a message" do
      conv = insert_conversation()

      assert {:ok, message} =
               Conversations.create_message(%{
                 conversation_id: conv.id,
                 source: :email,
                 body: "Test message",
                 is_internal_note: false
               })

      assert message.body == "Test message"
      assert message.conversation_id == conv.id
    end
  end

  describe "create_message!/1" do
    test "creates a message and returns it" do
      conv = insert_conversation()

      message =
        Conversations.create_message!(%{
          conversation_id: conv.id,
          source: :portal,
          body: "Test message",
          is_internal_note: false
        })

      assert message.body == "Test message"
      assert message.source == :portal
    end

    test "raises on invalid attributes" do
      conv = insert_conversation()

      assert_raise Ecto.InvalidChangesetError, fn ->
        Conversations.create_message!(%{
          conversation_id: conv.id,
          source: :email
          # missing body
        })
      end
    end
  end

  describe "update_state/2" do
    test "updates conversation state" do
      conv = insert_conversation(state: :new)

      assert {:ok, updated} = Conversations.update_state(conv, :active)
      assert updated.state == :active
    end
  end

  describe "snooze/2" do
    test "sets snoozed_until timestamp" do
      conv = insert_conversation()
      until = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)

      assert {:ok, snoozed} = Conversations.snooze(conv, until)
      assert snoozed.snoozed_until == until
    end
  end

  describe "update_conversation/2" do
    test "updates conversation with arbitrary attributes" do
      conv = insert_conversation(cached_score: 10)

      assert {:ok, updated} =
               Conversations.update_conversation(conv, %{cached_score: 50})

      assert updated.cached_score == 50
    end

    test "updates last_operator_action_at" do
      conv = insert_conversation()
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      assert {:ok, updated} =
               Conversations.update_conversation(conv, %{last_operator_action_at: now})

      assert updated.last_operator_action_at == now
    end
  end

  describe "reload!/1" do
    test "reloads conversation from database" do
      conv = insert_conversation(cached_score: 10)

      # Update the score directly in the database
      Custyard.Repo.update!(Ecto.Changeset.change(conv, cached_score: 99))

      # Original struct still has old value
      assert conv.cached_score == 10

      # Reloaded struct has new value
      reloaded = Conversations.reload!(conv)
      assert reloaded.cached_score == 99
    end
  end

  describe "task functions" do
    test "create_task/1 creates a task" do
      conv = insert_conversation()

      assert {:ok, task} =
               Conversations.create_task(%{title: "Fix bug", conversation_id: conv.id})

      assert task.title == "Fix bug"
      assert task.state == :open
    end

    test "get_task!/1 retrieves a task" do
      conv = insert_conversation()
      {:ok, task} = Conversations.create_task(%{title: "Test", conversation_id: conv.id})

      result = Conversations.get_task!(task.id)
      assert result.id == task.id
    end

    test "update_task_state/2 changes task state" do
      conv = insert_conversation()
      {:ok, task} = Conversations.create_task(%{title: "Test", conversation_id: conv.id})

      assert {:ok, updated} = Conversations.update_task_state(task, :in_progress)
      assert updated.state == :in_progress
    end

    test "update_task/2 updates task attributes" do
      conv = insert_conversation()
      {:ok, task} = Conversations.create_task(%{title: "Test", conversation_id: conv.id})

      assert {:ok, updated} =
               Conversations.update_task(task, %{title: "Updated", portal_visible: false})

      assert updated.title == "Updated"
      assert updated.portal_visible == false
    end

    test "delete_task/1 removes a task" do
      conv = insert_conversation()
      {:ok, task} = Conversations.create_task(%{title: "Test", conversation_id: conv.id})

      assert {:ok, _} = Conversations.delete_task(task)
      assert_raise Ecto.NoResultsError, fn -> Conversations.get_task!(task.id) end
    end
  end

  describe "list_portal_visible_tasks/1" do
    test "returns only portal-visible tasks" do
      conv = insert_conversation()

      {:ok, visible} =
        Conversations.create_task(%{
          title: "Visible",
          conversation_id: conv.id,
          portal_visible: true
        })

      {:ok, _hidden} =
        Conversations.create_task(%{
          title: "Hidden",
          conversation_id: conv.id,
          portal_visible: false
        })

      results = Conversations.list_portal_visible_tasks(conv.id)
      ids = Enum.map(results, & &1.id)

      assert ids == [visible.id]
    end

    test "orders tasks by inserted_at" do
      conv = insert_conversation()
      {:ok, first} = Conversations.create_task(%{title: "First", conversation_id: conv.id})
      {:ok, second} = Conversations.create_task(%{title: "Second", conversation_id: conv.id})

      results = Conversations.list_portal_visible_tasks(conv.id)
      ids = Enum.map(results, & &1.id)

      assert ids == [first.id, second.id]
    end
  end
end
