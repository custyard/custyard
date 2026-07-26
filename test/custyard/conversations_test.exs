defmodule Custyard.ConversationsTest do
  # SQLite doesn't support async tests due to database locking
  use Custyard.DataCase, async: false

  alias Custyard.Auth.Token
  alias Custyard.Email.Outbound
  alias Custyard.{Conversations, Intake, Prospect}

  import Custyard.Factory
  import Swoosh.TestAssertions

  describe "list_neglected" do
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

    test "org scoping includes nil-org conversations and excludes other orgs" do
      org = insert_organization()
      other_org = insert_organization()

      own = insert_conversation(organization_id: org.id)
      other = insert_conversation(organization_id: other_org.id)
      unlinked = insert_conversation(organization_id: nil, source: :disambiguation)

      results = Conversations.list_neglected(organization_id: org.id)
      ids = Enum.map(results, & &1.id)

      assert own.id in ids
      assert unlinked.id in ids
      refute other.id in ids
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

    test "org scoping includes nil-org conversations and excludes other orgs" do
      org = insert_organization()
      other_org = insert_organization()

      own = insert_conversation(organization_id: org.id)
      other = insert_conversation(organization_id: other_org.id)
      unlinked = insert_conversation(organization_id: nil, source: :disambiguation)

      results = Conversations.list_for_attention_queue(organization_id: org.id)
      ids = Enum.map(results, & &1.conversation.id)

      assert own.id in ids
      assert unlinked.id in ids
      refute other.id in ids
    end

    test "unscoped (super_admin) queue includes nil-org conversations" do
      org = insert_organization()
      own = insert_conversation(organization_id: org.id)
      unlinked = insert_conversation(organization_id: nil, source: :disambiguation)

      results = Conversations.list_for_attention_queue()
      ids = Enum.map(results, & &1.conversation.id)

      assert own.id in ids
      assert unlinked.id in ids
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
      assert Conversations.get_conversation(99_999) == nil
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
        Conversations.get_conversation!(99_999)
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
      assert {:error, :not_found} = Conversations.get_conversation_for_organization(99_999, 1)
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

  describe "soft_delete_message/2" do
    test "stamps deleted_at and the deleting operator, keeping the original body" do
      conv = insert_conversation()
      message = insert_message(conversation_id: conv.id, body: "Sensitive content")
      operator = insert_operator_account()

      assert {:ok, deleted} = Conversations.soft_delete_message(message, operator)

      assert %DateTime{} = deleted.deleted_at
      assert deleted.deleted_by_operator_id == operator.id

      # Soft delete only: the row and its original body stay in the database.
      reloaded = Repo.get!(Custyard.Message, message.id)
      assert reloaded.body == "Sensitive content"
      assert %DateTime{} = reloaded.deleted_at
    end

    test "broadcasts message_updated on the conversation topic" do
      conv = insert_conversation()
      message = insert_message(conversation_id: conv.id)
      operator = insert_operator_account()

      Phoenix.PubSub.subscribe(Custyard.PubSub, "conversation:#{conv.id}")

      assert {:ok, _deleted} = Conversations.soft_delete_message(message, operator)

      conv_id = conv.id
      assert_received {:message_updated, ^conv_id}
    end

    test "is idempotent and preserves the original deletion attribution" do
      conv = insert_conversation()
      message = insert_message(conversation_id: conv.id)
      first_operator = insert_operator_account()
      second_operator = insert_operator_account()

      {:ok, deleted} = Conversations.soft_delete_message(message, first_operator)
      assert {:ok, unchanged} = Conversations.soft_delete_message(deleted, second_operator)

      assert unchanged.deleted_at == deleted.deleted_at
      assert unchanged.deleted_by_operator_id == first_operator.id

      reloaded = Repo.get!(Custyard.Message, message.id)
      assert reloaded.deleted_by_operator_id == first_operator.id
    end
  end

  describe "update_state/2" do
    test "updates conversation state" do
      conv = insert_conversation(state: :new)

      assert {:ok, updated} = Conversations.update_state(conv, :active)
      assert updated.state == :active
    end

    test "allows valid state transitions" do
      # :new -> :active
      conv = insert_conversation(state: :new)
      assert {:ok, _} = Conversations.update_state(conv, :active)

      # :active -> :waiting
      conv = insert_conversation(state: :active)
      assert {:ok, _} = Conversations.update_state(conv, :waiting)

      # :waiting -> :dormant
      conv = insert_conversation(state: :waiting)
      assert {:ok, _} = Conversations.update_state(conv, :dormant)

      # :dormant -> :active (reactivate)
      conv = insert_conversation(state: :dormant)
      assert {:ok, _} = Conversations.update_state(conv, :active)

      # :active -> :resolved
      conv = insert_conversation(state: :active)
      assert {:ok, _} = Conversations.update_state(conv, :resolved)

      # :resolved -> :active (reopen)
      conv = insert_conversation(state: :resolved)
      assert {:ok, _} = Conversations.update_state(conv, :active)
    end

    test "prevents invalid state transitions" do
      # :new cannot go directly to :dormant
      conv = insert_conversation(state: :new)
      assert {:error, changeset} = Conversations.update_state(conv, :dormant)
      assert %{state: [error_msg]} = errors_on(changeset)
      assert error_msg =~ "cannot transition from new to dormant"

      # :new cannot go to :waiting
      conv = insert_conversation(state: :new)
      assert {:error, changeset} = Conversations.update_state(conv, :waiting)
      assert %{state: [_]} = errors_on(changeset)

      # :resolved cannot go to :waiting
      conv = insert_conversation(state: :resolved)
      assert {:error, changeset} = Conversations.update_state(conv, :waiting)
      assert %{state: [_]} = errors_on(changeset)

      # :dormant cannot go to :waiting
      conv = insert_conversation(state: :dormant)
      assert {:error, changeset} = Conversations.update_state(conv, :waiting)
      assert %{state: [_]} = errors_on(changeset)
    end

    test "allows same state (no-op)" do
      conv = insert_conversation(state: :active)
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
    test "updates conversation with valid attributes" do
      conv = insert_conversation()

      assert {:ok, updated} =
               Conversations.update_conversation(conv, %{subject: "Updated subject"})

      assert updated.subject == "Updated subject"
    end

    test "ignores cached_score in attrs (computed field)" do
      conv = insert_conversation(cached_score: 10)

      # cached_score should not be updatable via changeset
      assert {:ok, updated} =
               Conversations.update_conversation(conv, %{cached_score: 9999, subject: "Test"})

      # Score unchanged (input ignored)
      assert updated.cached_score == 10
      # But valid attrs still applied
      assert updated.subject == "Test"
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

  describe "send_reply/3" do
    setup do
      org = insert_organization(name: "Reply Corp")
      contact = insert_contact(organization_id: org.id, email: "customer@example.com")

      conversation =
        insert_conversation(
          organization_id: org.id,
          contact_id: contact.id,
          subject: "Need help",
          state: :waiting
        )

      # Add a customer message to thread against
      _customer_msg =
        insert_message(
          conversation_id: conversation.id,
          source: :email,
          sender_email: "customer@example.com",
          message_id: "<inbound-123@customer.com>",
          body: "Please help me"
        )

      {:ok, org: org, contact: contact, conversation: conversation}
    end

    test "creates a message with correct attributes", %{conversation: conv} do
      {:ok, message} = Conversations.send_reply(conv, "Here is your answer")

      assert message.source == :operator
      assert message.body == "Here is your answer"
      assert message.is_internal_note == false
      assert message.conversation_id == conv.id
      assert message.delivery_status == :pending
    end

    test "sets in_reply_to from last customer message", %{conversation: conv} do
      {:ok, message} = Conversations.send_reply(conv, "Following up")

      assert message.in_reply_to == "<inbound-123@customer.com>"
    end

    test "threads in_reply_to to the latest customer message when messages were preloaded ascending",
         %{conversation: conv} do
      # Backdate the setup message so the newer one wins on inserted_at
      backdated =
        DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      Repo.update_all(
        from(m in Custyard.Message, where: m.conversation_id == ^conv.id),
        set: [inserted_at: backdated]
      )

      insert_message(
        conversation_id: conv.id,
        source: :email,
        message_id: "<inbound-456@customer.com>",
        body: "Any update?"
      )

      # get_with_messages/1 preloads messages ascending — the same shape the
      # LiveView passes in. Regression: the already-loaded association must
      # not decide which message gets threaded.
      preloaded = Conversations.get_with_messages(conv.id)

      {:ok, message} = Conversations.send_reply(preloaded, "Reply to the follow-up")

      assert message.in_reply_to == "<inbound-456@customer.com>"
    end

    test "breaks inserted_at ties for in_reply_to by message id", %{conversation: conv} do
      # Inserted within the same second as the setup message
      insert_message(
        conversation_id: conv.id,
        source: :email,
        message_id: "<inbound-tie@customer.com>",
        body: "Second message, same second"
      )

      {:ok, message} = Conversations.send_reply(conv, "Tiebreak reply")

      assert message.in_reply_to == "<inbound-tie@customer.com>"
    end

    test "generates a unique outbound message_id", %{conversation: conv} do
      {:ok, message} = Conversations.send_reply(conv, "Reply one")

      assert message.message_id != nil
      assert String.starts_with?(message.message_id, "<")
      assert String.ends_with?(message.message_id, ">")
      assert message.message_id =~ ~r/c#{conv.id}@/
    end

    test "transitions conversation state to :active", %{conversation: conv} do
      assert conv.state == :waiting

      {:ok, _message} = Conversations.send_reply(conv, "On it")

      reloaded = Repo.get!(Custyard.Conversation, conv.id)
      assert reloaded.state == :active
    end

    test "updates last_operator_action_at", %{conversation: conv} do
      assert conv.last_operator_action_at == nil

      {:ok, _message} = Conversations.send_reply(conv, "Done")

      reloaded = Repo.get!(Custyard.Conversation, conv.id)
      assert reloaded.last_operator_action_at != nil
    end

    test "uses operator_email option for sender when no route from_address", %{conversation: conv} do
      {:ok, message} = Conversations.send_reply(conv, "Reply", operator_email: "agent@corp.com")

      assert message.sender_email == "agent@corp.com"
    end

    test "prefers route from_address over operator_email", %{conversation: conv, org: org} do
      # Create a route with a from_address for this org
      insert_inbound_route(
        organization_id: org.id,
        route_type: :general,
        from_address: "support@acme.com"
      )

      {:ok, message} =
        Conversations.send_reply(conv, "Reply", operator_email: "agent@corp.com")

      assert message.sender_email == "support@acme.com"
    end

    test "prefers project route from_address for project-routed conversations", %{
      org: org,
      contact: contact
    } do
      project = insert_project(organization_id: org.id)

      conversation =
        insert_conversation(
          organization_id: org.id,
          contact_id: contact.id,
          project_id: project.id,
          subject: "Project thread"
        )

      insert_inbound_route(
        organization_id: org.id,
        route_type: :general,
        from_address: "support@acme.com"
      )

      insert_inbound_route(
        organization_id: org.id,
        route_type: :project,
        project_id: project.id,
        from_address: "projects@acme.com"
      )

      {:ok, message} = Conversations.send_reply(conversation, "Project reply")

      assert message.sender_email == "projects@acme.com"
    end

    test "falls back to the general route when the project route has no from_address", %{
      org: org,
      contact: contact
    } do
      project = insert_project(organization_id: org.id)

      conversation =
        insert_conversation(
          organization_id: org.id,
          contact_id: contact.id,
          project_id: project.id,
          subject: "Project thread"
        )

      insert_inbound_route(
        organization_id: org.id,
        route_type: :general,
        from_address: "support@acme.com"
      )

      insert_inbound_route(
        organization_id: org.id,
        route_type: :project,
        project_id: project.id
      )

      {:ok, message} = Conversations.send_reply(conversation, "Project reply")

      assert message.sender_email == "support@acme.com"
    end

    test "returns error on empty body", %{conversation: conv} do
      # Empty body should fail validation since body is required
      result = Conversations.send_reply(conv, "")

      assert {:error, _reason} = result
    end

    test "sets origin to :email for email-sourced conversation", %{conversation: conv} do
      # Default conversation source is :email
      {:ok, message} = Conversations.send_reply(conv, "Reply to email thread")

      assert message.origin == :email
    end

    test "sets origin to :lettermint for lettermint-sourced conversation" do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, email: "lm-customer@example.com")

      conversation =
        insert_conversation(
          organization_id: org.id,
          contact_id: contact.id,
          subject: "Lettermint thread",
          source: :lettermint
        )

      insert_message(
        conversation_id: conversation.id,
        source: :email,
        message_id: "<lm-msg@lettermint.test>",
        body: "Hello from lettermint"
      )

      {:ok, message} = Conversations.send_reply(conversation, "Lettermint reply")

      assert message.origin == :lettermint
    end

    test "sets origin to :portal for portal-sourced conversation" do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, email: "portal-user@example.com")

      conversation =
        insert_conversation(
          organization_id: org.id,
          contact_id: contact.id,
          subject: "Portal thread",
          source: :portal
        )

      insert_message(
        conversation_id: conversation.id,
        source: :portal,
        body: "Portal message"
      )

      {:ok, message} = Conversations.send_reply(conversation, "Portal reply")

      assert message.origin == :portal
    end

    test "defaults origin to :email for disambiguation-sourced conversation" do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, email: "ambig@example.com")

      conversation =
        insert_conversation(
          organization_id: org.id,
          contact_id: contact.id,
          subject: "Disambiguation thread",
          source: :disambiguation
        )

      insert_message(
        conversation_id: conversation.id,
        source: :email,
        body: "Disambiguated message"
      )

      {:ok, message} = Conversations.send_reply(conversation, "Disambiguation reply")

      assert message.origin == :email
    end

    test "broadcasts PubSub events on success", %{conversation: conv} do
      conv_id = conv.id

      Phoenix.PubSub.subscribe(Custyard.PubSub, "conversation:#{conv_id}")
      Phoenix.PubSub.subscribe(Custyard.PubSub, "conversations")
      Phoenix.PubSub.subscribe(Custyard.PubSub, "conversations:org:#{conv.organization_id}")

      {:ok, _message} = Conversations.send_reply(conv, "Broadcast test")

      assert_received {:message_added, ^conv_id}
      assert_received {:conversation_updated, ^conv_id}
      assert_received {:conversation_updated, ^conv_id}
    end

    test "sender_email is nil when no route and no operator_email", %{conversation: conv} do
      {:ok, message} = Conversations.send_reply(conv, "No sender")

      assert message.sender_email == nil
    end

    test "message and conversation update are atomic", %{conversation: conv} do
      # Verify both the message insert and conversation update happen together
      before_count =
        Repo.one(
          from m in Custyard.Message,
            where: m.conversation_id == ^conv.id and m.source == :operator,
            select: count()
        )

      {:ok, message} = Conversations.send_reply(conv, "Atomic test")

      after_count =
        Repo.one(
          from m in Custyard.Message,
            where: m.conversation_id == ^conv.id and m.source == :operator,
            select: count()
        )

      # Exactly one operator message was created
      assert after_count == before_count + 1

      # Both the message and conversation update succeeded
      reloaded_conv = Repo.get!(Custyard.Conversation, conv.id)
      assert reloaded_conv.state == :active
      assert reloaded_conv.last_operator_action_at != nil
      assert message.conversation_id == conv.id
    end

    test "reply on a nil-org conversation broadcasts on the global topic" do
      conversation =
        insert_conversation(
          organization_id: nil,
          source: :disambiguation,
          subject: "Unlinked reply thread"
        )

      conv_id = conversation.id

      Phoenix.PubSub.subscribe(Custyard.PubSub, "conversation:#{conv_id}")
      Phoenix.PubSub.subscribe(Custyard.PubSub, "conversations")

      {:ok, message} = Conversations.send_reply(conversation, "Reply to unlinked prospect")

      assert message.source == :operator
      assert_received {:message_added, ^conv_id}
      assert_received {:conversation_updated, ^conv_id}
    end

    test "reply on a nil-org conversation never broadcasts to the malformed bare org topic" do
      conversation =
        insert_conversation(
          organization_id: nil,
          source: :disambiguation,
          subject: "Unlinked reply thread"
        )

      # Subscribing only to the malformed topic a nil org would interpolate
      # into isolates this assertion from the legitimate "conversations" topic.
      Phoenix.PubSub.subscribe(Custyard.PubSub, "conversations:org:")

      {:ok, _message} = Conversations.send_reply(conversation, "Reply to unlinked prospect")

      refute_received {:conversation_updated, _id}
    end
  end

  describe "broadcast_to_org/2" do
    test "publishes to the org-scoped topic for a real organization id" do
      Phoenix.PubSub.subscribe(Custyard.PubSub, "conversations:org:123")

      assert :ok = Conversations.broadcast_to_org(123, {:conversation_updated, 7})

      assert_received {:conversation_updated, 7}
    end

    test "skips the broadcast entirely when organization_id is nil" do
      Phoenix.PubSub.subscribe(Custyard.PubSub, "conversations:org:")

      assert :ok = Conversations.broadcast_to_org(nil, {:conversation_updated, 7})

      refute_received {:conversation_updated, 7}
    end
  end

  describe "reply_channel/1" do
    test "prefers the linked contact's email" do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, email: "customer@example.com")
      conv = insert_conversation(organization_id: org.id, contact_id: contact.id)

      assert Conversations.reply_channel(conv) == {:contact, "customer@example.com"}
    end

    test "contact email wins over a captured prospect email" do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, email: "customer@example.com")
      conv = insert_conversation(source: :public_intake, contact_id: contact.id)

      insert_prospect(conversation_id: conv.id, email: "prospect@example.com")

      assert Conversations.reply_channel(conv) == {:contact, "customer@example.com"}
    end

    test "falls back to a captured, non-revoked prospect email" do
      conv = insert_conversation(source: :public_intake)
      insert_prospect(conversation_id: conv.id, email: "prospect@example.com")

      assert Conversations.reply_channel(conv) == {:prospect, "prospect@example.com"}
    end

    test "returns :none when the prospect email is revoked" do
      conv = insert_conversation(source: :public_intake)

      insert_prospect(
        conversation_id: conv.id,
        email: "prospect@example.com",
        revoked_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

      assert Conversations.reply_channel(conv) == :none
    end

    test "returns :none when the prospect has no email" do
      conv = insert_conversation(source: :public_intake)
      insert_prospect(conversation_id: conv.id)

      assert Conversations.reply_channel(conv) == :none
    end

    test "returns :none with neither contact nor prospect" do
      conv = insert_conversation(source: :public_intake)

      assert Conversations.reply_channel(conv) == :none
    end

    test "list_for_attention_queue/1 preloads the prospect for reply_channel" do
      conv = insert_conversation(source: :public_intake, state: :new)
      insert_prospect(conversation_id: conv.id, email: "prospect@example.com")

      [%{conversation: loaded}] = Conversations.list_for_attention_queue()

      assert Ecto.assoc_loaded?(loaded.prospect)
      assert Ecto.assoc_loaded?(loaded.contact)
      assert Conversations.reply_channel(loaded) == {:prospect, "prospect@example.com"}
    end
  end

  describe "send_reply/3 consent gate (public intake)" do
    test "prospect with opt-in: reply is pending and delivers to the prospect email" do
      {conversation, _prospect} =
        intake_fixture(email: "prospect@example.com", notify_on_reply: true)

      {:ok, message} = Conversations.send_reply(conversation, "Happy to help")
      assert message.delivery_status == :pending

      # Async delivery is disabled in test config; exercise delivery directly.
      {:ok, delivered} = Outbound.deliver(message)
      assert delivered.delivery_status == :sent

      assert_email_sent(fn email ->
        assert email.to == [{"", "prospect@example.com"}]
      end)
    end

    test "prospect without opt-in: reply is withheld and delivery is skipped" do
      {conversation, _prospect} =
        intake_fixture(email: "prospect@example.com", notify_on_reply: false)

      {:ok, message} = Conversations.send_reply(conversation, "Saved but not emailed")

      assert message.delivery_status == :withheld
      assert Repo.get!(Custyard.Message, message.id).delivery_status == :withheld
      assert_no_email_sent()
    end

    test "no captured email at all: reply is withheld" do
      {conversation, _prospect} = intake_fixture([])

      {:ok, message} = Conversations.send_reply(conversation, "No recipient anywhere")

      assert message.delivery_status == :withheld
      assert_no_email_sent()
    end

    test "revoked prospect has no reply channel: reply is withheld" do
      revoked_at = DateTime.utc_now() |> DateTime.truncate(:second)

      {conversation, _prospect} =
        intake_fixture(
          email: "prospect@example.com",
          notify_on_reply: true,
          revoked_at: revoked_at
        )

      {:ok, message} = Conversations.send_reply(conversation, "Revoked prospect")

      assert message.delivery_status == :withheld
      assert_no_email_sent()
    end

    test "non-intake conversation with no recipient keeps the visible failure path" do
      org = insert_organization()
      conversation = insert_conversation(organization_id: org.id, contact_id: nil)

      {:ok, message} = Conversations.send_reply(conversation, "No recipient anywhere")

      # :withheld is reserved for the public-intake consent gate — a
      # non-intake no-recipient reply stays :pending and delivery records
      # the failure visibly.
      assert message.delivery_status == :pending

      assert {:error, :no_recipient_email, failed} = Outbound.deliver(message)
      assert failed.delivery_status == :failed
      assert_no_email_sent()
    end

    test "contact channel delivers unconditionally even when the prospect has not opted in" do
      org = insert_organization()
      contact = insert_contact(organization_id: org.id, email: "matched@example.com")

      conversation =
        insert_conversation(
          source: :public_intake,
          organization_id: org.id,
          contact_id: contact.id,
          subject: "Matched an existing contact at capture"
        )

      insert_prospect(
        conversation_id: conversation.id,
        email: "prospect@example.com",
        notify_on_reply: false
      )

      {:ok, message} = Conversations.send_reply(conversation, "Established customer path")
      assert message.delivery_status == :pending

      {:ok, delivered} = Outbound.deliver(message)
      assert delivered.delivery_status == :sent

      assert_email_sent(fn email ->
        assert email.to == [{"", "matched@example.com"}]
      end)
    end

    test "public-intake replies never carry the operator's personal address" do
      {conversation, _prospect} =
        intake_fixture(email: "prospect@example.com", notify_on_reply: true)

      {:ok, message} =
        Conversations.send_reply(conversation, "Reply",
          operator_email: "operator-personal@example.com"
        )

      assert message.sender_email == nil
    end

    test "public-intake sender stays platform-addressed after linking to an org with a route" do
      org = insert_organization()

      insert_inbound_route(
        organization_id: org.id,
        route_type: :general,
        from_address: "support@acme.com"
      )

      conversation =
        insert_conversation(
          source: :public_intake,
          organization_id: org.id,
          subject: "Linked intake thread"
        )

      insert_prospect(
        conversation_id: conversation.id,
        email: "prospect@example.com",
        notify_on_reply: true
      )

      {:ok, message} =
        Conversations.send_reply(conversation, "Reply",
          operator_email: "operator-personal@example.com"
        )

      # Source-keyed rule: neither the org route address nor the operator's
      # personal address — nil selects Outbound's platform fallback.
      assert message.sender_email == nil
    end

    test "sets origin to :email for public-intake conversations" do
      {conversation, _prospect} =
        intake_fixture(email: "prospect@example.com", notify_on_reply: true)

      {:ok, message} = Conversations.send_reply(conversation, "Origin check")

      assert message.origin == :email
    end

    test "toggling notify_on_reply between replies flips delivery" do
      {conversation, prospect} =
        intake_fixture(email: "prospect@example.com", notify_on_reply: false)

      {:ok, first} = Conversations.send_reply(fresh(conversation), "First reply")
      assert first.delivery_status == :withheld

      {:ok, _} = prospect |> Prospect.notification_changeset(true) |> Repo.update()

      {:ok, second} = Conversations.send_reply(fresh(conversation), "Second reply")
      assert second.delivery_status == :pending

      {:ok, delivered} = Outbound.deliver(second)
      assert delivered.delivery_status == :sent

      assert_email_sent(fn email ->
        assert email.to == [{"", "prospect@example.com"}]
      end)

      {:ok, _} =
        Repo.get!(Prospect, prospect.id)
        |> Prospect.notification_changeset(false)
        |> Repo.update()

      {:ok, third} = Conversations.send_reply(fresh(conversation), "Third reply")
      assert third.delivery_status == :withheld
    end
  end

  describe "cleanup_resolved_conversations/2" do
    test "purges resolved non-intake conversations after 90 days and keeps younger ones" do
      org = insert_organization()
      old = insert_conversation(organization_id: org.id, state: :resolved)
      young = insert_conversation(organization_id: org.id, state: :resolved)
      backdate_updated_at(old, 91)
      backdate_updated_at(young, 89)

      assert Conversations.cleanup_resolved_conversations(90) == 1
      assert Repo.get(Custyard.Conversation, old.id) == nil
      assert Repo.get(Custyard.Conversation, young.id)
    end

    test "keeps resolved public-intake conversations well past the 90-day bound" do
      conversation = insert_conversation(source: :public_intake, state: :resolved)
      backdate_updated_at(conversation, 364)

      assert Conversations.cleanup_resolved_conversations(90) == 0
      assert Repo.get(Custyard.Conversation, conversation.id)
    end

    test "purges resolved public-intake conversations after 365 days" do
      conversation = insert_conversation(source: :public_intake, state: :resolved)
      backdate_updated_at(conversation, 366)

      assert Conversations.cleanup_resolved_conversations(90) == 1
      assert Repo.get(Custyard.Conversation, conversation.id) == nil
    end

    test "purges resolved conversations with a NULL source column at the standard bound" do
      # The DB column has no NOT NULL constraint (only the Ecto schema
      # default), so a legacy row or a bypass-the-schema insert can leave
      # source NULL. Force it directly, bypassing the changeset default.
      conversation = insert_conversation(state: :resolved)
      backdate_updated_at(conversation, 91)

      Repo.update_all(
        from(c in Custyard.Conversation, where: c.id == ^conversation.id),
        set: [source: nil]
      )

      assert Conversations.cleanup_resolved_conversations(90) == 1
      assert Repo.get(Custyard.Conversation, conversation.id) == nil
    end

    test "dry run counts the retention split without deleting" do
      org = insert_organization()
      non_intake = insert_conversation(organization_id: org.id, state: :resolved)
      intake_young = insert_conversation(source: :public_intake, state: :resolved)
      intake_old = insert_conversation(source: :public_intake, state: :resolved)
      backdate_updated_at(non_intake, 91)
      backdate_updated_at(intake_young, 120)
      backdate_updated_at(intake_old, 366)

      assert Conversations.cleanup_resolved_conversations(90, dry_run: true) == 2
      assert Repo.get(Custyard.Conversation, non_intake.id)
      assert Repo.get(Custyard.Conversation, intake_young.id)
      assert Repo.get(Custyard.Conversation, intake_old.id)
    end

    test "purging cascades to the prospect so the access token stops resolving" do
      {token, hash} = Token.generate()
      conversation = insert_conversation(source: :public_intake, state: :resolved)
      prospect = insert_prospect(conversation_id: conversation.id, access_token_hash: hash)
      backdate_updated_at(conversation, 366)

      assert {:ok, _conversation} = Intake.get_conversation_by_access_token(token)

      assert Conversations.cleanup_resolved_conversations(90) == 1

      assert Repo.get(Prospect, prospect.id) == nil
      assert Intake.get_conversation_by_access_token(token) == {:error, :not_found}
    end

    test "run_cleanup applies the public-intake retention split" do
      intake_old = insert_conversation(source: :public_intake, state: :resolved)
      intake_young = insert_conversation(source: :public_intake, state: :resolved)
      backdate_updated_at(intake_old, 366)
      backdate_updated_at(intake_young, 120)

      %{resolved_conversations: count} = Conversations.run_cleanup(dry_run: true)
      assert count == 1
    end

    # The non-dry path was never exercised: cleanup_orphaned_contacts/1
    # expressed its anti-join as a DELETE-with-JOIN, which SQLite rejects,
    # so run_cleanup/1 raised on any real invocation. It is scheduled now
    # (Conversations.RetentionSweep), so this pins the whole path.
    test "run_cleanup deletes for real, not only under dry_run" do
      intake_old = insert_conversation(source: :public_intake, state: :resolved)
      intake_young = insert_conversation(source: :public_intake, state: :resolved)
      backdate_updated_at(intake_old, 366)
      backdate_updated_at(intake_young, 120)

      counts = Conversations.run_cleanup()

      assert counts.resolved_conversations == 1
      refute Repo.get(Custyard.Conversation, intake_old.id)
      assert Repo.get(Custyard.Conversation, intake_young.id)
    end

    test "run_cleanup removes contacts left with no conversations" do
      org = insert_organization()
      orphan = insert_contact(organization_id: org.id)
      kept = insert_contact(organization_id: org.id)
      _live = insert_conversation(organization_id: org.id, contact_id: kept.id, state: :active)

      counts = Conversations.run_cleanup()

      assert counts.orphaned_contacts >= 1
      refute Repo.get(Custyard.Contact, orphan.id)
      assert Repo.get(Custyard.Contact, kept.id)
    end
  end

  # --- helpers ---

  # Public-intake conversation with a prospect message and a prospect row.
  defp intake_fixture(prospect_overrides) do
    conversation = insert_conversation(source: :public_intake, subject: "Intake question")

    insert_message(
      conversation_id: conversation.id,
      source: :prospect,
      sender_email: nil,
      body: "Hello, can you help me?"
    )

    prospect =
      insert_prospect(
        Keyword.merge(
          [
            conversation_id: conversation.id,
            email_captured_at: DateTime.utc_now() |> DateTime.truncate(:second)
          ],
          prospect_overrides
        )
      )

    {conversation, prospect}
  end

  # Re-read without preloaded associations so send_reply sees fresh consent.
  defp fresh(conversation), do: Conversations.get_conversation!(conversation.id)

  defp backdate_updated_at(conversation, days) do
    backdated =
      DateTime.utc_now()
      |> DateTime.add(-days * 24 * 60 * 60, :second)
      |> DateTime.truncate(:second)

    Repo.update_all(
      from(c in Custyard.Conversation, where: c.id == ^conversation.id),
      set: [updated_at: backdated]
    )
  end
end
