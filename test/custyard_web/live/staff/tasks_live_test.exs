defmodule CustyardWeb.Staff.TasksLiveTest do
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Custyard.Factory
  import Ecto.Query, only: [from: 2]

  alias Custyard.{Repo, StaffAccount, Threads, WorkItem}

  setup %{conn: conn} do
    {:ok, staff} =
      %StaffAccount{}
      |> StaffAccount.changeset(%{
        role: "admin",
        tenant_id: Process.get(:factory_tenant_id),
        email: "test@example.com",
        password: "password123"
      })
      |> Repo.insert()

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> put_staff_session(staff.id)

    {:ok, conn: conn, staff: staff}
  end

  defp from_now(seconds) do
    DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(seconds, :second)
  end

  defp task(org, title, attrs \\ []) do
    insert_task([title: title, organization_id: org.id, portal_visible: false] ++ attrs)
  end

  defp row(task), do: "[data-testid=staff-task-row-#{task.id}]"
  defp chip(name), do: "[data-testid=staff-tasks-filter-#{name}]"

  # The number a chip shows.
  defp chip_count(view, name) do
    view
    |> element("[data-testid=staff-tasks-filter-count-#{name}]")
    |> render()
    |> Floki.parse_fragment!()
    |> Floki.text()
    |> String.trim()
    |> String.to_integer()
  end

  # The task ids in the order the page lists them.
  defp listed(view) do
    ~r/data-testid="staff-task-row-(\d+)"/
    |> Regex.scan(render(view), capture: :all_but_first)
    |> Enum.map(fn [id] -> String.to_integer(id) end)
  end

  # One task of every kind the chips tell apart.
  defp every_kind(org) do
    %{
      overdue: task(org, "Overdue task", due_at: from_now(-3 * 86_400 - 60)),
      upcoming: task(org, "Upcoming task", due_at: from_now(2 * 86_400 + 3600)),
      undated: task(org, "Undated task", state: :in_progress),
      finished: task(org, "Finished task", state: :done, due_at: from_now(-86_400))
    }
  end

  describe "default view" do
    test "lists the unfinished tasks with the queue's controls", %{conn: conn} do
      org = insert_organization(name: "Acme")
      tasks = every_kind(org)

      {:ok, view, _html} = live(conn, ~p"/app/tasks")

      assert has_element?(view, "[data-testid=staff-tasks-page]")
      assert has_element?(view, "[data-testid=staff-tasks-heading]", "All tasks")
      assert has_element?(view, "[data-testid=staff-tasks-count]", "3 tasks")
      assert has_element?(view, "[data-testid=staff-tasks-keys]", "move")

      assert has_element?(
               view,
               "[data-testid=staff-tasks-sort][data-reversed=false]",
               "Due soonest first"
             )

      # Due date first, undated last; the finished task is not listed.
      assert listed(view) == [tasks.overdue.id, tasks.upcoming.id, tasks.undated.id]

      assert has_element?(view, "#{chip("open")}[aria-pressed=true]", "open")
      assert has_element?(view, "#{chip("due")}[aria-pressed=false]", "due")
      assert has_element?(view, chip("no_date"), "no due date")

      for {name, count} <- [open: 3, due: 1, upcoming: 1, no_date: 1, done: 1, all: 4] do
        assert chip_count(view, name) == count, "#{name} should count #{count}"
      end

      # The list is the one the keys of the attention queue work on.
      assert has_element?(
               view,
               "ul#staff-tasks-list[phx-hook=QueueKeys][data-testid=staff-tasks-list]"
             )

      assert has_element?(
               view,
               "#{row(tasks.overdue)} a[data-row-link][data-testid=staff-task-row-link]"
             )
    end

    test "says task, not tasks, for one", %{conn: conn} do
      task(insert_organization(), "Only task")

      {:ok, view, _html} = live(conn, ~p"/app/tasks")

      assert view |> element("[data-testid=staff-tasks-count]") |> render() =~ ~r/1 task\s*</
    end

    test "tasks of another tenant are not listed or counted", %{conn: conn} do
      mine = task(insert_organization(), "Mine")
      other_org = insert_organization(tenant_id: insert_tenant().id)
      theirs = insert_task(title: "Theirs", organization_id: other_org.id)

      {:ok, view, html} = live(conn, ~p"/app/tasks?filter=all")

      assert has_element?(view, row(mine))
      refute has_element?(view, row(theirs))
      refute html =~ "Theirs"
      assert has_element?(view, "[data-testid=staff-tasks-count]", "1 task")
    end
  end

  describe "rows" do
    test "show the state, the title, where the task lives and the customer", %{conn: conn} do
      org = insert_organization(name: "Acme")
      thread = insert_thread(organization_id: org.id, subject: "Refund request")
      project = insert_project(organization_id: org.id, title: "Onboarding")

      in_thread = insert_task(title: "Call the bank", thread_id: thread.id, portal_visible: false)

      in_project =
        insert_task(title: "Send the plan", project_id: project.id, state: :in_progress)

      direct = task(org, "Renew the contract", state: :done)

      {:ok, view, _html} = live(conn, ~p"/app/tasks?filter=all")

      assert has_element?(view, "#{row(in_thread)}[data-state=open]")
      assert has_element?(view, "#{row(in_thread)} [data-testid=staff-task-status]", "Open")

      assert has_element?(
               view,
               "#{row(in_thread)} [data-testid=staff-task-title]",
               "Call the bank"
             )

      assert has_element?(
               view,
               "#{row(in_thread)} [data-testid=staff-task-place]",
               "Refund request"
             )

      assert has_element?(
               view,
               "#{row(in_thread)} [data-testid=staff-task-place]",
               "Conversation:"
             )

      assert has_element?(view, "#{row(in_thread)} [data-testid=staff-task-customer]", "Acme")

      assert has_element?(
               view,
               "#{row(in_project)} [data-testid=staff-task-status]",
               "In progress"
             )

      assert has_element?(view, "#{row(in_project)} [data-testid=staff-task-place]", "Onboarding")
      assert has_element?(view, "#{row(in_project)} [data-testid=staff-task-place]", "Project:")
      assert has_element?(view, "#{row(in_project)} [data-testid=staff-task-customer]", "Acme")

      assert has_element?(view, "#{row(direct)}[data-state=done]")
      assert has_element?(view, "#{row(direct)} [data-testid=staff-task-status]", "Done")
      refute has_element?(view, "#{row(direct)} [data-testid=staff-task-place]")
      assert has_element?(view, "#{row(direct)} [data-testid=staff-task-customer]", "Acme")
    end

    test "link to the conversation, else the project, else the customer", %{conn: conn} do
      org = insert_organization(name: "Acme")
      thread = insert_thread(organization_id: org.id)
      project = insert_project(organization_id: org.id)

      in_thread = insert_task(title: "In a conversation", thread_id: thread.id)
      in_both = insert_task(title: "In both", thread_id: thread.id, project_id: project.id)
      in_project = insert_task(title: "In a project", project_id: project.id)
      direct = task(org, "For the customer")

      {:ok, view, _html} = live(conn, ~p"/app/tasks")

      link = "a[data-testid=staff-task-row-link]"

      assert has_element?(view, "#{row(in_thread)} #{link}[href='/app/threads/#{thread.id}']")
      assert has_element?(view, "#{row(in_both)} #{link}[href='/app/threads/#{thread.id}']")
      assert has_element?(view, "#{row(in_project)} #{link}[href='/app/projects/#{project.id}']")

      assert has_element?(
               view,
               "#{row(direct)} #{link}[href='/app/customers/#{org.public_id}']"
             )

      # The row link opens the page it names.
      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element("#{row(in_project)} #{link}") |> render_click()

      assert to == "/app/projects/#{project.id}"
    end

    test "say when a task is due, and overdue stands out", %{conn: conn} do
      org = insert_organization()
      overdue = task(org, "Overdue", due_at: from_now(-3 * 86_400 - 60))
      upcoming = task(org, "Upcoming", due_at: ~U[2099-03-04 14:00:00Z])
      undated = task(org, "Undated")
      finished = task(org, "Finished", state: :done, due_at: ~U[2025-03-04 14:00:00Z])

      {:ok, view, _html} = live(conn, ~p"/app/tasks?filter=all")

      due = "[data-testid=staff-task-due]"

      assert has_element?(view, "#{row(overdue)}[data-due=overdue].border-l-red-500")
      assert has_element?(view, "#{row(overdue)} #{due}.text-red-600", "overdue 3d")

      assert has_element?(
               view,
               "#{row(overdue)} #{due}[title='Due #{CustyardWeb.StaffComponents.format_timestamp(overdue.due_at)}']"
             )

      assert has_element?(view, "#{row(upcoming)}[data-due=upcoming].border-l-transparent")
      assert view |> element("#{row(upcoming)} #{due}") |> render() =~ ~r/due in \d+d/

      assert has_element?(
               view,
               "#{row(upcoming)} #{due}[title='Due Mar 4, 2099 14:00 UTC'] time[datetime='2099-03-04T14:00:00Z']"
             )

      refute has_element?(view, "#{row(upcoming)} #{due}.text-red-600")

      assert has_element?(view, "#{row(undated)}[data-due=none] #{due}", "no due date")
      refute has_element?(view, "#{row(undated)} #{due}[title]")

      # A finished task keeps its date and is never overdue.
      assert has_element?(view, "#{row(finished)}[data-due=closed] #{due}", "due Mar 4, 2025")
      refute has_element?(view, "#{row(finished)} #{due}.text-red-600")
    end

    test "mark the tasks the customer can see in the portal", %{conn: conn} do
      org = insert_organization()
      shown = task(org, "Shown", portal_visible: true)
      hidden = task(org, "Hidden")

      {:ok, view, _html} = live(conn, ~p"/app/tasks")

      assert has_element?(view, "#{row(shown)} [data-testid=staff-task-portal]", "in portal")
      refute has_element?(view, "#{row(hidden)} [data-testid=staff-task-portal]")
    end
  end

  describe "filter chips" do
    test "each chip lists its tasks and is kept in the URL", %{conn: conn} do
      tasks = every_kind(insert_organization())

      {:ok, view, _html} = live(conn, ~p"/app/tasks")

      for {name, expected} <- [
            due: [:overdue],
            upcoming: [:upcoming],
            no_date: [:undated],
            done: [:finished],
            all: [:overdue, :upcoming, :undated, :finished]
          ] do
        view |> element(chip(name)) |> render_click()

        assert_patch(view, "/app/tasks?filter=#{name}")
        assert listed(view) == Enum.map(expected, &tasks[&1].id)
        assert has_element?(view, "#{chip(name)}[aria-pressed=true]")
        assert has_element?(view, "#{chip("open")}[aria-pressed=false]")
      end

      # The default filter is left out of the URL.
      view |> element(chip("open")) |> render_click()

      assert_patch(view, "/app/tasks")
      assert listed(view) == [tasks.overdue.id, tasks.upcoming.id, tasks.undated.id]
    end
  end

  describe "order" do
    test "the toggle reverses the list and is kept in the URL", %{conn: conn} do
      tasks = every_kind(insert_organization())
      in_order = [tasks.overdue.id, tasks.upcoming.id, tasks.undated.id]

      {:ok, view, _html} = live(conn, ~p"/app/tasks")
      assert listed(view) == in_order

      view |> element("[data-testid=staff-tasks-sort]") |> render_click()

      assert_patch(view, "/app/tasks?reverse=1")
      assert listed(view) == Enum.reverse(in_order)

      assert has_element?(
               view,
               "[data-testid=staff-tasks-sort][data-reversed=true]",
               "Due latest first"
             )

      view |> element("[data-testid=staff-tasks-sort]") |> render_click()

      assert_patch(view, "/app/tasks")
      assert listed(view) == in_order
    end
  end

  describe "customer select" do
    test "lists one customer's tasks and counts them", %{conn: conn} do
      acme = insert_organization(name: "Acme")
      globex = insert_organization(name: "Globex")
      acme_task = task(acme, "Acme task", due_at: from_now(-60))
      globex_task = task(globex, "Globex task")
      task(globex, "Globex done", state: :done)

      {:ok, view, _html} = live(conn, ~p"/app/tasks")

      assert has_element?(view, "label[for=tasks-customer]", "Customer")
      assert has_element?(view, "#tasks-customer option[value='']", "All customers")
      assert has_element?(view, "#tasks-customer option[value='#{acme.public_id}']", "Acme")
      assert listed(view) == [acme_task.id, globex_task.id]

      view |> form("#tasks-customer-filter") |> render_change(%{customer: globex.public_id})

      assert_patch(view, "/app/tasks?customer=#{globex.public_id}")
      assert listed(view) == [globex_task.id]
      assert has_element?(view, "#tasks-customer option[value='#{globex.public_id}'][selected]")
      assert chip_count(view, "open") == 1
      assert chip_count(view, "due") == 0
      assert chip_count(view, "done") == 1
      assert chip_count(view, "all") == 2

      view |> form("#tasks-customer-filter") |> render_change(%{customer: ""})

      assert_patch(view, "/app/tasks")
      assert listed(view) == [acme_task.id, globex_task.id]
    end

    test "is not shown when the tenant has no customers", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/tasks")

      refute has_element?(view, "#tasks-customer-filter")
    end
  end

  describe "URL state" do
    test "a link restores the filter, the order and the customer", %{conn: conn} do
      acme = insert_organization(name: "Acme")
      older = task(acme, "Done earlier", state: :done)
      newer = task(acme, "Done later", state: :done)
      task(acme, "Still open")
      task(insert_organization(name: "Globex"), "Globex done", state: :done)

      Repo.update_all(from(t in WorkItem, where: t.id == ^older.id),
        set: [updated_at: from_now(-3600)]
      )

      {:ok, view, _html} =
        live(conn, ~p"/app/tasks?filter=done&reverse=1&customer=#{acme.public_id}")

      # Most recently updated first, reversed.
      assert listed(view) == [older.id, newer.id]
      assert has_element?(view, "#{chip("done")}[aria-pressed=true]")
      assert has_element?(view, "[data-testid=staff-tasks-sort][data-reversed=true]")
      assert has_element?(view, "#tasks-customer option[value='#{acme.public_id}'][selected]")
      assert has_element?(view, "[data-testid=staff-tasks-count]", "2 tasks")
    end

    test "each control keeps what the others set", %{conn: conn} do
      acme = insert_organization(name: "Acme")
      task(acme, "Task")

      {:ok, view, _html} = live(conn, ~p"/app/tasks?filter=done&customer=#{acme.public_id}")

      view |> element("[data-testid=staff-tasks-sort]") |> render_click()
      assert_patch(view, "/app/tasks?filter=done&reverse=1&customer=#{acme.public_id}")

      view |> element(chip("all")) |> render_click()
      assert_patch(view, "/app/tasks?filter=all&reverse=1&customer=#{acme.public_id}")

      view |> form("#tasks-customer-filter") |> render_change(%{customer: ""})
      assert_patch(view, "/app/tasks?filter=all&reverse=1")
    end

    test "an unknown filter or customer falls back to the default", %{conn: conn} do
      org = insert_organization()
      open = task(org, "Open")
      task(org, "Done", state: :done)

      {:ok, view, _html} = live(conn, ~p"/app/tasks?filter=nonsense&customer=nobody&reverse=yes")

      assert listed(view) == [open.id]
      assert has_element?(view, "#{chip("open")}[aria-pressed=true]")
      assert has_element?(view, "[data-testid=staff-tasks-sort][data-reversed=false]")
      refute has_element?(view, "#tasks-customer option[selected]:not([value=''])")
    end

    test "another tenant's customer in the URL filters nothing in", %{conn: conn} do
      mine = task(insert_organization(), "Mine")
      other_org = insert_organization(tenant_id: insert_tenant().id)
      theirs = insert_task(title: "Theirs", organization_id: other_org.id)

      {:ok, view, _html} = live(conn, ~p"/app/tasks?filter=all&customer=#{other_org.public_id}")

      assert listed(view) == [mine.id]
      refute has_element?(view, row(theirs))
      refute has_element?(view, "#tasks-customer option[value='#{other_org.public_id}']")
    end
  end

  describe "mark done and reopen" do
    test "the row action marks a task done, and reopens it from the done list", %{conn: conn} do
      org = insert_organization()
      thread = insert_thread(organization_id: org.id)
      task = insert_task(title: "Call back", thread_id: thread.id)

      {:ok, view, _html} = live(conn, ~p"/app/tasks")

      action = "#{row(task)} button[data-testid=staff-task-action]"
      # Each row's button names its task, so a list of them can be told apart.
      assert has_element?(view, "#{action}[data-action=done][aria-label='Mark done: Call back']")

      view |> element(action) |> render_click()

      assert Repo.get!(WorkItem, task.id).state == :done
      # Done tasks leave the open list, and a screen reader is told why.
      refute has_element?(view, row(task))

      assert has_element?(
               view,
               "[data-testid=staff-tasks-announcement][role=status]",
               "Marked done: Call back"
             )

      assert chip_count(view, "open") == 0
      assert chip_count(view, "done") == 1

      view |> element(chip("done")) |> render_click()
      assert has_element?(view, "#{action}[data-action=reopen][aria-label='Reopen: Call back']")

      view |> element(action) |> render_click()

      assert Repo.get!(WorkItem, task.id).state == :open
      refute has_element?(view, row(task))
      assert chip_count(view, "open") == 1
      assert chip_count(view, "done") == 0
    end

    test "works for a project's task and a customer's task", %{conn: conn} do
      org = insert_organization()
      project = insert_project(organization_id: org.id)
      in_project = insert_task(title: "In a project", project_id: project.id)
      direct = task(org, "For the customer")
      Phoenix.PubSub.subscribe(Custyard.PubSub, "project:#{project.id}")
      project_id = project.id

      {:ok, view, _html} = live(conn, ~p"/app/tasks?filter=all")

      for task <- [in_project, direct] do
        view |> element("#{row(task)} [data-testid=staff-task-action]") |> render_click()

        assert Repo.get!(WorkItem, task.id).state == :done
        assert has_element?(view, "#{row(task)}[data-state=done]")
      end

      # The project page hears about its task, as when it is changed there.
      assert_receive {:project_updated, ^project_id}
    end

    test "tells the conversation and the queue, as the conversation page does", %{conn: conn} do
      thread = insert_thread()
      task = insert_task(title: "Call back", thread_id: thread.id)
      Phoenix.PubSub.subscribe(Custyard.PubSub, "threads")
      Phoenix.PubSub.subscribe(Custyard.PubSub, "thread:#{thread.id}")
      Phoenix.PubSub.subscribe(Custyard.PubSub, "threads:org:#{thread.organization_id}")
      thread_id = thread.id

      {:ok, view, _html} = live(conn, ~p"/app/tasks")
      view |> element("#{row(task)} [data-testid=staff-task-action]") |> render_click()

      # Once on each of the three topics.
      for _topic <- 1..3, do: assert_receive({:thread_updated, ^thread_id})
    end

    test "an agent may mark a task done, as on the conversation page" do
      agent = insert_staff_account(role: "agent")
      thread = insert_thread()
      task = insert_task(title: "Call back", thread_id: thread.id)

      conn =
        %{Phoenix.ConnTest.build_conn() | host: tenant_test_host()}
        |> Phoenix.ConnTest.init_test_session(%{})
        |> put_staff_session(agent)

      {:ok, view, _html} = live(conn, ~p"/app/tasks")
      view |> element("#{row(task)} [data-testid=staff-task-action]") |> render_click()

      assert Repo.get!(WorkItem, task.id).state == :done
    end

    test "a task that is not on the page is left alone", %{conn: conn} do
      other_org = insert_organization(tenant_id: insert_tenant().id)
      other_thread = insert_thread(organization_id: other_org.id)
      theirs = insert_task(title: "Theirs", thread_id: other_thread.id)
      task(insert_organization(), "Mine")

      {:ok, view, _html} = live(conn, ~p"/app/tasks")

      render_click(view, "set_task_state", %{"id" => to_string(theirs.id), "state" => "done"})

      assert Repo.get!(WorkItem, theirs.id).state == :open
    end

    test "a state the page does not offer is ignored", %{conn: conn} do
      task = task(insert_organization(), "Mine")

      {:ok, view, _html} = live(conn, ~p"/app/tasks")

      render_click(view, "set_task_state", %{"id" => to_string(task.id), "state" => "in_progress"})

      assert Repo.get!(WorkItem, task.id).state == :open
    end

    test "staff signed out elsewhere cannot change a task", %{conn: conn, staff: staff} do
      task = task(insert_organization(), "Mine")

      {:ok, view, _html} = live(conn, ~p"/app/tasks")

      # Signing out everywhere replaces the session claim.
      Repo.update_all(from(s in StaffAccount, where: s.id == ^staff.id),
        set: [session_claim: StaffAccount.generate_session_claim()]
      )

      assert {:error, {:redirect, %{to: "/app/login"}}} =
               view |> element("#{row(task)} [data-testid=staff-task-action]") |> render_click()

      assert Repo.get!(WorkItem, task.id).state == :open
    end

    test "a task deleted elsewhere is reported and leaves the list", %{conn: conn} do
      task = task(insert_organization(), "Short-lived")

      {:ok, view, _html} = live(conn, ~p"/app/tasks")
      Repo.delete!(task)

      html = view |> element("#{row(task)} [data-testid=staff-task-action]") |> render_click()

      assert html =~ "That task no longer exists"
      refute has_element?(view, row(task))
    end
  end

  describe "live refresh" do
    test "a task added in a conversation appears", %{conn: conn} do
      thread = insert_thread(subject: "Refund request")

      {:ok, view, _html} = live(conn, ~p"/app/tasks")
      assert has_element?(view, "[data-testid=staff-tasks-empty]")

      {:ok, task} = Threads.create_task(%{title: "Call back", thread_id: thread.id})

      # The reload is debounced, so the row appears a moment after the broadcast.
      assert Enum.any?(1..40, fn _ ->
               Process.sleep(50)
               has_element?(view, row(task))
             end)

      assert has_element?(view, "#{row(task)} [data-testid=staff-task-place]", "Refund request")
      assert chip_count(view, "open") == 1
    end

    test "a task added to a project appears", %{conn: conn} do
      project = insert_project(organization_id: insert_organization().id, title: "Onboarding")

      {:ok, view, _html} = live(conn, ~p"/app/tasks")
      assert has_element?(view, "[data-testid=staff-tasks-empty]")

      {:ok, task} = Threads.create_task(%{title: "Send the kit", project_id: project.id})

      assert Enum.any?(1..40, fn _ ->
               Process.sleep(50)
               has_element?(view, row(task))
             end)

      assert has_element?(view, "#{row(task)} [data-testid=staff-task-place]", "Onboarding")
    end

    test "the done list names its own order", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/tasks?filter=done")
      assert has_element?(view, "[data-testid=staff-tasks-sort]", "Latest change first")

      {:ok, view, _html} = live(conn, ~p"/app/tasks?filter=done&reverse=1")
      assert has_element?(view, "[data-testid=staff-tasks-sort]", "Earliest change first")
    end

    test "a task finished in its conversation leaves the open list", %{conn: conn} do
      thread = insert_thread()
      task = insert_task(title: "Call back", thread_id: thread.id)

      {:ok, view, _html} = live(conn, ~p"/app/tasks")
      assert has_element?(view, row(task))

      {:ok, _task} = Threads.update_task_state(task, :done)
      send(view.pid, :debounced_reload)

      refute has_element?(view, row(task))
      assert chip_count(view, "done") == 1
    end

    test "many changes in a row cost one reload", %{conn: conn} do
      thread = insert_thread()
      task = insert_task(title: "Call back", thread_id: thread.id)

      {:ok, view, _html} = live(conn, ~p"/app/tasks")

      for _n <- 1..5 do
        Phoenix.PubSub.broadcast(
          Custyard.PubSub,
          Threads.tasks_topic(task.tenant_id),
          {:task_changed, task.id}
        )
      end

      # Nothing is read while the changes keep coming.
      Repo.update_all(from(t in WorkItem, where: t.id == ^task.id), set: [title: "Renamed"])
      refute render(view) =~ "Renamed"

      assert Enum.any?(1..40, fn _ ->
               Process.sleep(50)
               render(view) =~ "Renamed"
             end)
    end

    test "a task that becomes due moves to the due chip on the next tick", %{conn: conn} do
      # Two seconds away, so the page is sure to load before the task is due.
      task = task(insert_organization(), "Due in a moment", due_at: from_now(2))

      {:ok, view, _html} = live(conn, ~p"/app/tasks")
      assert has_element?(view, "#{row(task)}[data-due=upcoming]")
      assert chip_count(view, "due") == 0

      assert Enum.any?(1..40, fn _ ->
               Process.sleep(100)
               send(view.pid, :tick)
               has_element?(view, "#{row(task)}[data-due=overdue]")
             end)

      assert chip_count(view, "due") == 1
      assert chip_count(view, "upcoming") == 0
    end

    test "a tick reads no tasks while none has become due", %{conn: conn} do
      task = task(insert_organization(), "Due tomorrow", due_at: from_now(86_400))

      {:ok, view, _html} = live(conn, ~p"/app/tasks")

      assert reads(fn ->
               send(view.pid, :tick)
               assert has_element?(view, row(task))
             end) == %{}
    end

    test "other messages are ignored", %{conn: conn} do
      task = task(insert_organization(), "Mine")

      {:ok, view, _html} = live(conn, ~p"/app/tasks")
      send(view.pid, {:thread_created, 1})
      send(view.pid, :something_else)

      assert has_element?(view, row(task))
    end
  end

  describe "empty states" do
    test "each filter says what is missing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/tasks")

      empty = "[data-testid=staff-tasks-empty]"
      assert has_element?(view, empty, "No open tasks.")
      refute has_element?(view, "[data-testid=staff-tasks-list]")
      assert has_element?(view, "[data-testid=staff-tasks-count]", "0 tasks")

      for {name, message} <- [
            due: "No tasks are due.",
            upcoming: "No upcoming tasks.",
            no_date: "No open tasks without a due date.",
            done: "No finished tasks.",
            all: "No tasks yet. Add a task from a conversation or a project."
          ] do
        view |> element(chip(name)) |> render_click()

        assert has_element?(view, empty, message)
      end
    end

    test "names the customer when one is selected", %{conn: conn} do
      acme = insert_organization(name: "Acme")
      task(insert_organization(name: "Globex"), "Globex task")

      {:ok, view, _html} = live(conn, ~p"/app/tasks?customer=#{acme.public_id}")

      assert has_element?(view, "[data-testid=staff-tasks-empty]", "No open tasks for Acme.")

      view |> element(chip("all")) |> render_click()

      assert has_element?(view, "[data-testid=staff-tasks-empty]", "No tasks yet for Acme.")
    end
  end

  describe "page load" do
    setup do
      org = insert_organization()
      thread = insert_thread(organization_id: org.id)
      project = insert_project(organization_id: org.id)

      for n <- 1..4 do
        insert_task(title: "Conversation #{n}", thread_id: thread.id)
        insert_task(title: "Project #{n}", project_id: project.id)
        task(org, "Customer #{n}")
      end

      :ok
    end

    test "reads the tasks, the counts and the customers once per render", %{conn: conn} do
      # A first visit renders twice: the plain page, then the connected one.
      assert reads(fn -> {:ok, _view, _html} = live(conn, ~p"/app/tasks?filter=all") end) ==
               %{"tasks" => 4, "organizations" => 2}
    end

    test "a chip reads the tasks and the counts again, and nothing per row", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/app/tasks")

      assert reads(fn -> view |> element(chip("all")) |> render_click() end) == %{"tasks" => 2}
    end
  end

  # Queries this test and its page make while `fun` runs, by table. The staff
  # and tenant lookups every staff page makes are left out.
  defp reads(fun) do
    test = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:custyard, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        if self() == test or test in Process.get(:"$callers", []),
          do: send(test, {id, metadata.source})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    id
    |> drain([])
    |> Enum.reject(&(&1 in ["staff_accounts", "tenants", "tenant_hosts"]))
    |> Enum.frequencies()
  end

  defp drain(id, sources) do
    receive do
      {^id, source} -> drain(id, [source | sources])
    after
      0 -> sources
    end
  end
end
