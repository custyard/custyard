defmodule Custyard.TaskAttentionTest do
  use Custyard.DataCase, async: true
  import Custyard.Factory

  defp scope_for(org) do
    staff = insert_staff_account(role: "admin", tenant_id: org.tenant_id)
    Custyard.Scope.for_staff(staff, Custyard.Tenants.get_tenant!(org.tenant_id))
  end

  alias Custyard.Conversations

  test "due unfinished tasks surface resolved and snoozed conversations until completed" do
    org = insert_organization()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    conversation =
      insert_conversation(
        organization_id: org.id,
        state: :resolved,
        snoozed_until: DateTime.add(now, 86_400)
      )

    {:ok, task} =
      Conversations.create_task(%{
        title: "Check fix",
        conversation_id: conversation.id,
        due_at: DateTime.add(now, -60)
      })

    assert [%{conversation: %{id: id}, due_task_count: 1}] =
             Conversations.list(scope_for(org), filter: "due_tasks", organization_id: org.id)

    assert id == conversation.id
    assert [_] = Conversations.list(scope_for(org), organization_id: org.id)
    {:ok, _} = Conversations.update_task_state(task, :done)
    assert [] = Conversations.list(scope_for(org), organization_id: org.id)
  end

  test "future tasks do not reopen resolved conversations and due tasks remain scoped" do
    org = insert_organization()
    other = insert_organization()
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    future = insert_conversation(organization_id: org.id, state: :resolved)
    foreign = insert_conversation(organization_id: other.id, state: :resolved)

    Conversations.create_task(%{
      title: "Later",
      conversation_id: future.id,
      due_at: DateTime.add(now, 3600)
    })

    Conversations.create_task(%{
      title: "Foreign",
      conversation_id: foreign.id,
      due_at: DateTime.add(now, -60)
    })

    assert [] =
             Conversations.list(scope_for(org), filter: "due_tasks", organization_id: org.id)
  end

  test "task changes notify the conversation and attention queue" do
    conversation = insert_conversation()
    Phoenix.PubSub.subscribe(Custyard.PubSub, "conversations")

    {:ok, task} =
      Conversations.create_task(%{title: "Follow up", conversation_id: conversation.id})

    assert_receive {:conversation_updated, id}
    assert id == conversation.id
    Conversations.update_task_state(task, :done)
    assert_receive {:conversation_updated, ^id}
  end

  test "editing a linked task through its project also refreshes the conversation" do
    conversation = insert_conversation()
    project = insert_project(organization_id: conversation.organization_id)
    Phoenix.PubSub.subscribe(Custyard.PubSub, "conversation:#{conversation.id}")

    {:ok, task} =
      Custyard.Projects.create_task(project, %{
        title: "Follow up",
        conversation_id: conversation.id
      })

    assert_receive {:conversation_updated, id}
    assert id == conversation.id
    {:ok, task} = Custyard.Projects.update_task_state(task, :done, broadcast?: false)
    assert_receive {:conversation_updated, ^id}
    Custyard.Projects.delete_task(task)
    assert_receive {:conversation_updated, ^id}
  end
end
