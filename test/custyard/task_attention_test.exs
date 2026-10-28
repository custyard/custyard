defmodule Custyard.TaskAttentionTest do
  use Custyard.DataCase, async: true
  import Custyard.Factory

  defp scope_for(org) do
    staff = insert_staff_account(role: "admin", tenant_id: org.tenant_id)
    Custyard.Scope.for_staff(staff, Custyard.Tenants.get_tenant!(org.tenant_id))
  end

  alias Custyard.Threads

  test "due unfinished tasks surface resolved and snoozed threads until completed" do
    org = insert_organization()
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    thread =
      insert_thread(
        organization_id: org.id,
        state: :resolved,
        snoozed_until: DateTime.add(now, 86_400)
      )

    {:ok, task} =
      Threads.create_task(%{
        title: "Check fix",
        thread_id: thread.id,
        due_at: DateTime.add(now, -60)
      })

    assert [%{thread: %{id: id}, due_task_count: 1}] =
             Threads.list(scope_for(org), filter: "due_tasks", organization_id: org.id)

    assert id == thread.id
    assert [_] = Threads.list(scope_for(org), organization_id: org.id)
    {:ok, _} = Threads.update_task_state(task, :done)
    assert [] = Threads.list(scope_for(org), organization_id: org.id)
  end

  test "future tasks do not reopen resolved threads and due tasks remain scoped" do
    org = insert_organization()
    other = insert_organization()
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    future = insert_thread(organization_id: org.id, state: :resolved)
    foreign = insert_thread(organization_id: other.id, state: :resolved)

    Threads.create_task(%{
      title: "Later",
      thread_id: future.id,
      due_at: DateTime.add(now, 3600)
    })

    Threads.create_task(%{
      title: "Foreign",
      thread_id: foreign.id,
      due_at: DateTime.add(now, -60)
    })

    assert [] =
             Threads.list(scope_for(org), filter: "due_tasks", organization_id: org.id)
  end

  test "task changes notify the thread and attention queue" do
    thread = insert_thread()
    Phoenix.PubSub.subscribe(Custyard.PubSub, "threads")

    {:ok, task} =
      Threads.create_task(%{title: "Follow up", thread_id: thread.id})

    assert_receive {:thread_updated, id}
    assert id == thread.id
    Threads.update_task_state(task, :done)
    assert_receive {:thread_updated, ^id}
  end

  test "editing a linked task through its project also refreshes the thread" do
    thread = insert_thread()
    project = insert_project(organization_id: thread.organization_id)
    Phoenix.PubSub.subscribe(Custyard.PubSub, "thread:#{thread.id}")

    {:ok, task} =
      Custyard.Projects.create_task(project, %{
        title: "Follow up",
        thread_id: thread.id
      })

    assert_receive {:thread_updated, id}
    assert id == thread.id
    {:ok, task} = Custyard.Projects.update_task_state(task, :done, broadcast?: false)
    assert_receive {:thread_updated, ^id}
    Custyard.Projects.delete_task(task)
    assert_receive {:thread_updated, ^id}
  end
end
