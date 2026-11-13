defmodule Custyard.TasksTest do
  use Custyard.DataCase, async: true

  import Custyard.Factory

  alias Custyard.{Scope, StaffAccount, Tasks, Tenant, Thread, Threads, WorkItem}

  # Every list and count below is taken at this moment, so "due" and
  # "upcoming" do not depend on when the suite runs.
  @now ~U[2026-11-12 12:00:00Z]

  setup do
    scope = staff_scope()
    org = insert_organization(name: "Acme")
    %{scope: scope, org: org}
  end

  defp at(seconds), do: DateTime.add(@now, seconds, :second)

  defp task(org, title, attrs \\ []) do
    insert_task([title: title, organization_id: org.id, portal_visible: false] ++ attrs)
  end

  # Timestamps are written by the database layer; the order tests need them
  # set apart by more than the second a test takes.
  defp stamp(task, fields) do
    Repo.update_all(from(t in WorkItem, where: t.id == ^task.id), set: fields)
    task
  end

  defp titles(tasks), do: Enum.map(tasks, & &1.title)

  defp list(scope, opts), do: Tasks.list(scope, [now: @now] ++ opts)
  defp counts(scope, opts \\ []), do: Tasks.counts(scope, [now: @now] ++ opts)

  # One task of every kind the filters tell apart.
  defp every_kind(org) do
    task(org, "overdue", due_at: at(-3600))
    task(org, "due now", due_at: @now, state: :in_progress)
    task(org, "upcoming", due_at: at(86_400))
    task(org, "undated")
    task(org, "finished", due_at: at(-7200), state: :done)
    task(org, "finished undated", state: :done)
    :ok
  end

  describe "filters" do
    setup %{org: org}, do: every_kind(org)

    test "open is the default and lists every unfinished task", %{scope: scope} do
      expected = ["due now", "overdue", "undated", "upcoming"]

      assert scope |> list([]) |> titles() |> Enum.sort() == expected
      assert scope |> list(filter: "open") |> titles() |> Enum.sort() == expected
      assert Tasks.default_filter() == "open"
    end

    test "due lists unfinished tasks whose due date is reached", %{scope: scope} do
      assert scope |> list(filter: "due") |> titles() |> Enum.sort() == ["due now", "overdue"]
    end

    test "upcoming lists unfinished tasks with a later due date", %{scope: scope} do
      assert scope |> list(filter: "upcoming") |> titles() == ["upcoming"]
    end

    test "no_date lists unfinished tasks without a due date", %{scope: scope} do
      assert scope |> list(filter: "no_date") |> titles() == ["undated"]
    end

    test "done lists finished tasks, dated or not", %{scope: scope} do
      assert scope |> list(filter: "done") |> titles() |> Enum.sort() ==
               ["finished", "finished undated"]
    end

    test "all lists everything", %{scope: scope} do
      assert scope |> list(filter: "all") |> length() == 6
    end

    test "an unknown name lists the default", %{scope: scope} do
      assert scope |> list(filter: "nonsense") |> titles() |> Enum.sort() ==
               scope |> list(filter: "open") |> titles() |> Enum.sort()
    end

    test "the names are the ones the page shows", %{scope: scope} do
      assert Tasks.filters() == ~w(open due upcoming no_date done all)
      assert scope |> counts() |> Map.keys() |> Enum.sort() == Enum.sort(Tasks.filters())
    end
  end

  describe "order" do
    setup %{org: org} do
      task(org, "due later", due_at: at(7200))
      task(org, "due first", due_at: at(-7200))

      task(org, "same date, older", due_at: at(3600))
      |> stamp(inserted_at: at(-86_400 * 2))

      task(org, "same date, newer", due_at: at(3600))
      |> stamp(inserted_at: at(-86_400))

      task(org, "undated, older") |> stamp(inserted_at: at(-86_400 * 2))
      task(org, "undated, newer") |> stamp(inserted_at: at(-86_400))

      # The due dates would put these the other way round.
      task(org, "done long ago", state: :done, due_at: at(-86_400 * 9))
      |> stamp(updated_at: at(-86_400 * 3))

      task(org, "done just now", state: :done, due_at: at(-86_400))
      |> stamp(updated_at: at(-60))

      :ok
    end

    @in_order [
      "due first",
      "same date, newer",
      "same date, older",
      "due later",
      "undated, newer",
      "undated, older",
      "done just now",
      "done long ago"
    ]

    test "due date first with undated tasks last, then newest; done by last update", %{
      scope: scope
    } do
      assert scope |> list(filter: "all") |> titles() == @in_order
      assert scope |> list(filter: "open") |> titles() == Enum.take(@in_order, 6)
      assert scope |> list(filter: "done") |> titles() == Enum.drop(@in_order, 6)
    end

    test "reverse gives the exact reverse", %{scope: scope} do
      for filter <- Tasks.filters() do
        assert scope |> list(filter: filter, reverse: true) |> titles() ==
                 scope |> list(filter: filter) |> titles() |> Enum.reverse()
      end
    end

    test "tasks equal in every date keep one order, and reverse still reverses it", %{
      scope: scope,
      org: org
    } do
      twins = for n <- 1..3, do: task(org, "twin #{n}", due_at: at(86_400 * 30))
      for twin <- twins, do: stamp(twin, inserted_at: at(-10), updated_at: at(-10))

      listed = scope |> list(filter: "upcoming") |> titles() |> Enum.filter(&(&1 =~ "twin"))
      assert listed == ["twin 3", "twin 2", "twin 1"]

      assert scope
             |> list(filter: "upcoming", reverse: true)
             |> titles()
             |> Enum.filter(&(&1 =~ "twin")) == Enum.reverse(listed)
    end
  end

  describe "what a row shows" do
    test "the conversation, the project and the customer come with the list", %{
      scope: scope,
      org: org
    } do
      thread = insert_thread(organization_id: org.id, subject: "Refund request")
      project = insert_project(organization_id: org.id, title: "Onboarding")

      insert_task(title: "in a conversation", thread_id: thread.id)
      insert_task(title: "in a project", project_id: project.id)
      task(org, "for the customer")

      insert_task(title: "in both", thread_id: thread.id, project_id: project.id)

      rows = Map.new(list(scope, []), &{&1.title, &1})

      assert rows["in a conversation"].thread.subject == "Refund request"
      assert rows["in a conversation"].project == nil
      assert rows["in a project"].project.title == "Onboarding"
      assert rows["in a project"].thread == nil
      assert rows["for the customer"].thread == nil
      assert rows["for the customer"].project == nil
      assert rows["in both"].thread.id == thread.id
      assert rows["in both"].project.id == project.id

      for {_title, row} <- rows do
        assert row.organization.name == "Acme"
        assert row.organization.public_id == org.public_id
      end
    end

    test "a task takes the customer its conversation was linked to later", %{
      scope: scope,
      org: org
    } do
      thread = insert_thread(source: :public_intake, subject: "From the website")
      {:ok, task} = Threads.create_task(%{title: "call back", thread_id: thread.id})
      assert task.organization_id == nil

      assert [%{organization: nil}] = list(scope, [])

      Repo.update_all(from(c in Thread, where: c.id == ^thread.id),
        set: [organization_id: org.id]
      )

      assert [%{organization: %{name: "Acme"}}] = list(scope, [])
      assert scope |> list(organization_id: org.id) |> titles() == ["call back"]
    end

    test "a task of an internal project has no customer", %{scope: scope} do
      project =
        insert_project(
          organization_id: nil,
          tenant_id: scope.tenant_id,
          project_type: :internal,
          portal_visible: false,
          title: "Tooling"
        )

      insert_task(title: "internal", project_id: project.id)

      assert [%{title: "internal", organization: nil, project: %{title: "Tooling"}}] =
               list(scope, [])
    end

    test "tasks of project templates are left out", %{scope: scope, org: org} do
      template = insert_project(organization_id: org.id, is_template: true, title: "Template")
      insert_task(title: "copied into new projects", project_id: template.id)
      task(org, "real work")

      assert scope |> list(filter: "all") |> titles() == ["real work"]
      assert counts(scope)["all"] == 1
    end
  end

  describe "customer filter" do
    test "lists and counts only that customer's tasks", %{scope: scope, org: acme} do
      other = insert_organization(name: "Globex")
      thread = insert_thread(organization_id: acme.id)
      project = insert_project(organization_id: acme.id)

      task(acme, "acme direct", due_at: at(-60))
      insert_task(title: "acme conversation", thread_id: thread.id)
      insert_task(title: "acme project", project_id: project.id, state: :done)
      task(other, "globex direct")

      assert scope |> list(filter: "all", organization_id: acme.id) |> titles() |> Enum.sort() ==
               ["acme conversation", "acme direct", "acme project"]

      assert scope |> list(filter: "all", organization_id: other.id) |> titles() ==
               ["globex direct"]

      assert %{"all" => 3, "open" => 2, "due" => 1, "done" => 1} =
               counts(scope, organization_id: acme.id)

      assert %{"all" => 1, "open" => 1, "no_date" => 1} =
               counts(scope, organization_id: other.id)

      assert counts(scope)["all"] == 4
    end
  end

  describe "counts" do
    test "every count equals the length of its list", %{scope: scope, org: acme} do
      every_kind(acme)

      globex = insert_organization(name: "Globex")
      every_kind(globex)
      task(globex, "one more overdue", due_at: at(-1))

      thread = insert_thread(source: :public_intake)
      insert_task(title: "no customer", thread_id: thread.id, due_at: at(60))

      template = insert_project(organization_id: acme.id, is_template: true)
      insert_task(title: "template", project_id: template.id)

      for customer <- [nil, acme.id, globex.id] do
        counted = counts(scope, organization_id: customer)

        for filter <- Tasks.filters() do
          listed = list(scope, filter: filter, organization_id: customer)

          assert counted[filter] == length(listed),
                 "#{filter} for customer #{inspect(customer)}: " <>
                   "counted #{counted[filter]}, listed #{length(listed)}"
        end
      end

      assert %{
               "open" => 10,
               "due" => 5,
               "upcoming" => 3,
               "no_date" => 2,
               "done" => 4,
               "all" => 14
             } =
               counts(scope)
    end

    test "an empty tenant counts zero for every filter", %{scope: scope} do
      assert counts(scope) == Map.new(Tasks.filters(), &{&1, 0})
    end
  end

  describe "page/2" do
    test "returns the list, the counts and when the next task becomes due", %{
      scope: scope,
      org: org
    } do
      every_kind(org)
      task(org, "upcoming sooner", due_at: at(600))

      page = Tasks.page(scope, filter: "due", now: @now)

      assert page.tasks |> titles() |> Enum.sort() == ["due now", "overdue"]
      assert page.counts == counts(scope)
      assert page.next_due_at == at(600)
    end

    test "nothing is upcoming: no next due time", %{scope: scope, org: org} do
      task(org, "overdue", due_at: at(-60))
      task(org, "finished", due_at: at(600), state: :done)

      assert Tasks.page(scope, now: @now).next_due_at == nil
    end

    test "runs the list query and the counts query once the staff member is known", %{
      scope: scope,
      org: org
    } do
      every_kind(org)
      thread = insert_thread(organization_id: org.id)
      for n <- 1..5, do: insert_task(title: "conversation #{n}", thread_id: thread.id)

      # Scope.current_staff/1 reads the staff account and the tenant.
      staff_check = count_queries(fn -> assert Scope.current_staff(scope) end)

      assert count_queries(fn -> Tasks.page(scope, filter: "all", now: @now) end) ==
               staff_check + 2
    end
  end

  describe "tenant isolation" do
    test "a tenant's staff see and count only their own tasks", %{scope: scope, org: org} do
      task(org, "ours")

      other_tenant = insert_tenant()
      other_org = insert_organization(tenant_id: other_tenant.id, name: "Elsewhere")
      other_thread = insert_thread(organization_id: other_org.id)
      insert_task(title: "theirs", organization_id: other_org.id)
      insert_task(title: "theirs, in a conversation", thread_id: other_thread.id)
      other_scope = staff_scope(other_tenant.id)

      assert scope |> list(filter: "all") |> titles() == ["ours"]
      assert counts(scope)["all"] == 1

      assert other_scope |> list(filter: "all") |> titles() |> Enum.sort() ==
               ["theirs", "theirs, in a conversation"]

      assert counts(other_scope)["all"] == 2

      # Naming another tenant's customer finds nothing.
      assert list(scope, filter: "all", organization_id: other_org.id) == []
      assert counts(scope, organization_id: other_org.id)["all"] == 0
    end
  end

  describe "staff visibility" do
    setup %{org: org} do
      other = insert_organization(name: "Globex")
      task(org, "acme task")
      task(other, "globex task")
      :ok
    end

    test "an agent sees the tasks of every customer, as an admin does", %{scope: admin} do
      agent = staff_scope(admin.tenant_id, "agent")

      assert agent |> list([]) |> titles() |> Enum.sort() == ["acme task", "globex task"]
      assert list(agent, []) == list(admin, [])
      assert counts(agent) == counts(admin)
    end

    test "a scope without a staff member sees nothing", %{scope: scope} do
      nobody = %Scope{tenant_id: scope.tenant_id, role: "admin"}

      assert list(nobody, filter: "all") == []
      assert counts(nobody) == Map.new(Tasks.filters(), &{&1, 0})
      assert Tasks.page(nobody) == %{tasks: [], counts: counts(nobody), next_due_at: nil}
    end

    test "a scope that is no longer current sees nothing", %{scope: scope} do
      # The role changed after the scope was built.
      Repo.update_all(from(s in StaffAccount, where: s.id == ^scope.staff_id),
        set: [role: "agent"]
      )

      assert list(scope, filter: "all") == []
      assert counts(scope)["all"] == 0
    end

    test "staff of a suspended tenant see nothing", %{scope: scope} do
      Repo.update_all(from(t in Tenant, where: t.id == ^scope.tenant_id),
        set: [status: "suspended"]
      )

      assert list(scope, filter: "all") == []
      assert counts(scope)["all"] == 0
    end
  end

  describe "set_state/3" do
    test "a conversation's task changes and tells the conversation and the queue", %{
      scope: scope,
      org: org
    } do
      thread = insert_thread(organization_id: org.id)
      task = insert_task(title: "follow up", thread_id: thread.id)
      Phoenix.PubSub.subscribe(Custyard.PubSub, "threads")
      Phoenix.PubSub.subscribe(Custyard.PubSub, "thread:#{thread.id}")
      thread_id = thread.id

      assert {:ok, %WorkItem{state: :done}} = Tasks.set_state(scope, task, :done)
      assert Repo.get!(WorkItem, task.id).state == :done
      # Once on each topic.
      assert_receive {:thread_updated, ^thread_id}
      assert_receive {:thread_updated, ^thread_id}

      assert {:ok, %WorkItem{state: :open}} = Tasks.set_state(scope, task, :open)
      assert Repo.get!(WorkItem, task.id).state == :open
    end

    test "a project's task changes and tells the project page", %{scope: scope, org: org} do
      project = insert_project(organization_id: org.id)
      task = insert_task(title: "kick off", project_id: project.id)
      Phoenix.PubSub.subscribe(Custyard.PubSub, "project:#{project.id}")
      project_id = project.id

      assert {:ok, %WorkItem{state: :done}} = Tasks.set_state(scope, task, :done)
      assert Repo.get!(WorkItem, task.id).state == :done
      assert_receive {:project_updated, ^project_id}
    end

    test "a task attached only to a customer changes", %{scope: scope, org: org} do
      task = task(org, "send the contract")

      assert {:ok, %WorkItem{state: :done}} = Tasks.set_state(scope, task, :done)
      assert Repo.get!(WorkItem, task.id).state == :done
      assert {:ok, %WorkItem{state: :open}} = Tasks.set_state(scope, task, :open)
      assert Repo.get!(WorkItem, task.id).state == :open
    end

    test "an agent may change a task, as on the conversation page", %{scope: scope, org: org} do
      agent = staff_scope(scope.tenant_id, "agent")
      thread = insert_thread(organization_id: org.id)
      task = insert_task(title: "follow up", thread_id: thread.id)

      assert {:ok, %WorkItem{state: :done}} = Tasks.set_state(agent, task, :done)
    end

    test "another tenant's tasks are refused, whatever they are attached to", %{scope: scope} do
      other_tenant = insert_tenant()
      other_org = insert_organization(tenant_id: other_tenant.id)
      thread = insert_thread(organization_id: other_org.id)
      project = insert_project(organization_id: other_org.id)

      in_thread = insert_task(title: "theirs", thread_id: thread.id)
      in_project = insert_task(title: "theirs", project_id: project.id)
      direct = insert_task(title: "theirs", organization_id: other_org.id)

      assert {:error, :unauthorized} = Tasks.set_state(scope, in_thread, :done)
      assert {:error, :unauthorized} = Tasks.set_state(scope, in_project, :done)
      assert {:error, :not_found} = Tasks.set_state(scope, direct, :done)

      for task <- [in_thread, in_project, direct] do
        assert Repo.get!(WorkItem, task.id).state == :open
      end
    end

    test "a scope that is no longer current is refused", %{scope: scope, org: org} do
      thread = insert_thread(organization_id: org.id)
      project = insert_project(organization_id: org.id)

      tasks = [
        insert_task(title: "a", thread_id: thread.id),
        insert_task(title: "b", project_id: project.id),
        task(org, "c")
      ]

      Repo.update_all(from(s in StaffAccount, where: s.id == ^scope.staff_id),
        set: [role: "agent"]
      )

      for task <- tasks do
        assert {:error, :unauthorized} = Tasks.set_state(scope, task, :done)
        assert Repo.get!(WorkItem, task.id).state == :open
      end
    end

    test "a task deleted since the page loaded is reported as gone", %{scope: scope, org: org} do
      thread = insert_thread(organization_id: org.id)
      project = insert_project(organization_id: org.id)

      tasks = [
        insert_task(title: "a", thread_id: thread.id),
        insert_task(title: "b", project_id: project.id),
        task(org, "c")
      ]

      for task <- tasks do
        Repo.delete!(task)
        assert {:error, :not_found} = Tasks.set_state(scope, task, :done)
      end
    end

    test "an unknown state is refused with the changeset", %{scope: scope, org: org} do
      task = task(org, "c")

      assert {:error, %Ecto.Changeset{}} = Tasks.set_state(scope, task, :archived)
      assert Repo.get!(WorkItem, task.id).state == :open
    end
  end

  # Queries made by this process while `fun` runs.
  defp count_queries(fun) do
    test = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:custyard, :repo, :query],
      fn _event, _measurements, _metadata, _config ->
        if self() == test, do: send(test, {id, :query})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    drain_queries(id, 0)
  end

  defp drain_queries(id, count) do
    receive do
      {^id, :query} -> drain_queries(id, count + 1)
    after
      0 -> count
    end
  end
end
