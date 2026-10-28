defmodule CustyardWeb.Staff.SupportWorkflowToolsTest do
  use CustyardWeb.ConnCase, async: true
  import Phoenix.LiveViewTest
  import Custyard.Factory
  alias Custyard.{Threads, Labels, Repo, Task}

  setup %{conn: conn} do
    staff = insert_staff_account(role: "admin")
    org = insert_organization()
    thread = insert_thread(organization_id: org.id, state: :active)
    conn = conn |> Phoenix.ConnTest.init_test_session(%{}) |> put_staff_session(staff.id)
    %{conn: conn, staff: staff, org: org, thread: thread}
  end

  test "task deadline and internal default round trip through the staff form", c do
    {:ok, view, _} = live(c.conn, ~p"/app/threads/#{c.thread.id}")
    view |> element("[phx-click=toggle_task_form]") |> render_click()
    assert has_element?(view, "label", "Due date and time (UTC)")
    refute has_element?(view, "[data-testid=staff-task-visible-checkbox][checked]")

    view
    |> form("form[phx-submit=add_task]", title: "Investigate invoice", due_at: "2026-11-20T16:45")
    |> render_submit()

    task = Repo.get_by!(Task, thread_id: c.thread.id)
    refute task.portal_visible
    assert task.due_at == ~U[2026-11-20 16:45:00Z]
    view |> element("[phx-click=edit_task][phx-value-id='#{task.id}']") |> render_click()
    assert has_element?(view, "[data-testid=staff-task-edit-due][value='2026-11-20T16:45']")

    assert render_submit(view, "save_task", %{"title" => task.title, "due_at" => "invalid"}) =~
             "Enter a valid due date"

    assert Repo.reload!(task).due_at == task.due_at
    assert Threads.list_portal_visible_tasks(c.thread.id) == []
  end

  test "labels can be created, applied and removed, and filter the attention queue", c do
    other = insert_thread(organization_id: c.org.id, state: :active)
    {:ok, view, _} = live(c.conn, ~p"/app/threads/#{c.thread.id}")
    view |> form("#create-label-form", name: "Billing") |> render_submit()

    %{assigned: [label]} =
      Labels.for_thread(
        Custyard.Scope.for_staff(c.staff, Custyard.Tenants.get_tenant!(c.staff.tenant_id)),
        c.thread
      )

    assert has_element?(view, "[data-testid='thread-label-#{label.id}']", "Billing")
    {:ok, queue, _} = live(c.conn, ~p"/app?label=#{label.id}")
    assert has_element?(queue, "[data-testid='staff-queue-card-#{c.thread.id}']")
    refute has_element?(queue, "[data-testid='staff-queue-card-#{other.id}']")
    view |> element("[phx-click=remove_label][phx-value-id='#{label.id}']") |> render_click()
    refute has_element?(view, "[data-testid='thread-label-#{label.id}']")
    view |> form("#assign-label-form", label_id: label.id) |> render_submit()
    assert has_element?(view, "[data-testid='thread-label-#{label.id}']")
  end

  test "an open queue refreshes tasks as their deadlines pass", c do
    {:ok, resolved} = Threads.update_state(c.thread, :resolved)
    future = DateTime.utc_now() |> DateTime.add(3600) |> DateTime.truncate(:second)

    {:ok, task} =
      Threads.create_task(%{
        title: "Follow up",
        thread_id: resolved.id,
        due_at: future
      })

    {:ok, view, _} = live(c.conn, ~p"/app?filter=due_tasks")
    refute has_element?(view, "[data-testid='staff-queue-card-#{resolved.id}']")
    task |> Ecto.Changeset.change(due_at: DateTime.add(future, -7200)) |> Repo.update!()
    send(view.pid, :refresh_deadlines)
    assert has_element?(view, "[data-testid='staff-queue-card-#{resolved.id}']")
    assert has_element?(view, "[data-testid=queue-tasks-due]", "1 task due")
  end

  test "unknown sends require reconciliation and expose no retry action", c do
    message =
      insert_message(
        thread_id: c.thread.id,
        source: :staff,
        delivery_status: :failed
      )

    message
    |> Ecto.Changeset.change(
      delivery_failure_kind: :unknown,
      delivery_attempted_at: DateTime.utc_now() |> DateTime.truncate(:second)
    )
    |> Repo.update!()

    {:ok, view, _} = live(c.conn, ~p"/app/threads/#{c.thread.id}")
    assert has_element?(view, "[data-testid=delivery-status-unknown]", "Delivery unknown")

    assert has_element?(
             view,
             "[data-testid='reply-recovery-#{message.id}']",
             "Check the provider"
           )

    refute has_element?(view, "[data-testid='retry-reply-#{message.id}']")
    render_click(view, "retry_reply", %{"id" => to_string(message.id)})
    assert Repo.reload!(message).delivery_status == :failed
  end

  test "a recipient change preserves the draft and requires review before sending", c do
    contact = insert_contact(organization_id: c.org.id, email: "alice@example.com")
    {:ok, _} = Threads.update_thread(c.thread, %{contact_id: contact.id})

    insert_message(
      thread_id: c.thread.id,
      source: :email,
      triage_class: :customer,
      sender_email: "alice@example.com",
      inserted_at: ~U[2026-10-26 12:00:00Z]
    )

    {:ok, view, _} = live(c.conn, ~p"/app/threads/#{c.thread.id}")
    assert has_element?(view, "[data-testid=staff-reply-to]", "alice@example.com")

    insert_message(
      thread_id: c.thread.id,
      source: :email,
      triage_class: :customer,
      sender_email: "bob@example.com",
      inserted_at: ~U[2026-10-26 13:00:00Z]
    )

    before_count = Threads.count_messages(c.thread.id)

    html = render_submit(view, "send_reply", %{"body" => "Keep this draft"})
    assert html =~ "The recipient changed. Review the updated reply before sending."
    assert has_element?(view, "[data-testid=staff-reply-to]", "bob@example.com")
    assert has_element?(view, "textarea[name=body]", "Keep this draft")
    assert Threads.count_messages(c.thread.id) == before_count
  end
end
