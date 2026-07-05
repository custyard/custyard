defmodule CustyardWeb.Operator.ProjectDetailLiveTest do
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Custyard.Factory

  alias Custyard.{OperatorAccount, Project, Repo, Task}

  setup %{conn: conn} do
    {:ok, operator} =
      %OperatorAccount{}
      |> OperatorAccount.changeset(%{email: "test@example.com", password: "password123"})
      |> Repo.insert()

    conn =
      conn
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:operator_id, operator.id)

    {:ok, conn: conn, operator: operator}
  end

  defp create_project(attrs) do
    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert!()
  end

  defp create_task(attrs) do
    %Task{}
    |> Task.changeset(attrs)
    |> Repo.insert!()
  end

  describe "mount/3" do
    test "renders project detail page", %{conn: conn} do
      org = insert_organization(name: "Acme Corp")
      project = create_project(%{title: "Website Redesign", organization_id: org.id})

      {:ok, _view, html} = live(conn, ~p"/operator/projects/#{project.id}")

      assert html =~ "Website Redesign"
      assert html =~ "Back to projects"
    end

    test "redirects when project not found", %{conn: conn} do
      {:error, {:live_redirect, %{to: redirect_path}}} =
        live(conn, ~p"/operator/projects/999999")

      assert redirect_path == "/operator/projects"
    end

    test "shows project description", %{conn: conn} do
      org = insert_organization()

      project =
        create_project(%{
          title: "Test Project",
          description: "A detailed project description",
          organization_id: org.id
        })

      {:ok, _view, html} = live(conn, ~p"/operator/projects/#{project.id}")

      assert html =~ "A detailed project description"
    end

    test "shows project dates", %{conn: conn} do
      org = insert_organization()

      project =
        create_project(%{
          title: "Test Project",
          organization_id: org.id,
          start_date: ~D[2026-04-01],
          target_completion_date: ~D[2026-05-01]
        })

      {:ok, _view, html} = live(conn, ~p"/operator/projects/#{project.id}")

      assert html =~ "Apr 01, 2026"
      assert html =~ "May 01, 2026"
    end
  end

  describe "task list" do
    test "shows tasks for the project", %{conn: conn} do
      org = insert_organization()
      project = create_project(%{title: "Test", organization_id: org.id})
      create_task(%{title: "First task", project_id: project.id})
      create_task(%{title: "Second task", project_id: project.id})

      {:ok, _view, html} = live(conn, ~p"/operator/projects/#{project.id}")

      assert html =~ "First task"
      assert html =~ "Second task"
    end

    test "shows empty state when no tasks", %{conn: conn} do
      org = insert_organization()
      project = create_project(%{title: "Test", organization_id: org.id})

      {:ok, _view, html} = live(conn, ~p"/operator/projects/#{project.id}")

      assert html =~ "No tasks in this project yet"
    end

    test "shows progress bar", %{conn: conn} do
      org = insert_organization()
      project = create_project(%{title: "Test", organization_id: org.id})
      create_task(%{title: "Done task", project_id: project.id, state: :done})
      create_task(%{title: "Open task", project_id: project.id, state: :open})

      {:ok, _view, html} = live(conn, ~p"/operator/projects/#{project.id}")

      assert html =~ "1 of 2 tasks completed"
      assert html =~ "50%"
    end
  end

  describe "add task" do
    test "shows task form when clicking add", %{conn: conn} do
      org = insert_organization()
      project = create_project(%{title: "Test", organization_id: org.id})

      {:ok, view, _html} = live(conn, ~p"/operator/projects/#{project.id}")

      html = view |> element("[data-testid=operator-add-task-btn]") |> render_click()

      assert html =~ "Task title"
      assert html =~ "Add Task"
      assert html =~ "Cancel"
    end

    test "creates a task", %{conn: conn} do
      org = insert_organization()
      project = create_project(%{title: "Test", organization_id: org.id})

      {:ok, view, _html} = live(conn, ~p"/operator/projects/#{project.id}")

      view |> element("[data-testid=operator-add-task-btn]") |> render_click()

      html =
        view
        |> form("[data-testid=operator-task-form]", %{title: "New task"})
        |> render_submit()

      assert html =~ "New task"
      assert Repo.get_by(Task, title: "New task", project_id: project.id)
    end

    test "creates task with portal visibility", %{conn: conn} do
      org = insert_organization()
      project = create_project(%{title: "Test", organization_id: org.id})

      {:ok, view, _html} = live(conn, ~p"/operator/projects/#{project.id}")

      view |> element("[data-testid=operator-add-task-btn]") |> render_click()

      view
      |> form("[data-testid=operator-task-form]", %{title: "Portal task", portal_visible: "true"})
      |> render_submit()

      task = Repo.get_by(Task, title: "Portal task")
      assert task.portal_visible == true
    end
  end

  describe "task state cycling" do
    test "cycles task state on click", %{conn: conn} do
      org = insert_organization()
      project = create_project(%{title: "Test", organization_id: org.id})
      task = create_task(%{title: "Task", project_id: project.id, state: :open})

      {:ok, view, html} = live(conn, ~p"/operator/projects/#{project.id}")
      assert html =~ "Open"

      html =
        view
        |> element("[data-testid=operator-task-state-btn-#{task.id}]")
        |> render_click()

      assert html =~ "In Progress"

      html =
        view
        |> element("[data-testid=operator-task-state-btn-#{task.id}]")
        |> render_click()

      assert html =~ "Done"
    end
  end

  describe "delete task" do
    test "deletes a task", %{conn: conn} do
      org = insert_organization()
      project = create_project(%{title: "Test", organization_id: org.id})
      task = create_task(%{title: "To delete", project_id: project.id})

      {:ok, view, html} = live(conn, ~p"/operator/projects/#{project.id}")
      assert html =~ "To delete"

      html =
        view
        |> element("[data-testid=operator-task-delete-#{task.id}]")
        |> render_click()

      refute html =~ "To delete"
      assert Repo.get(Task, task.id) == nil
    end
  end

  describe "navigation" do
    test "links to project from projects list", %{conn: conn} do
      org = insert_organization()
      project = create_project(%{title: "My Project", organization_id: org.id})

      {:ok, view, _html} = live(conn, ~p"/operator/projects")

      {:ok, _view, html} =
        view
        |> element("[data-testid=operator-project-view-#{project.id}]")
        |> render_click()
        |> follow_redirect(conn)

      assert html =~ "My Project"
      assert html =~ "Back to projects"
    end

    test "edit link navigates to the projects list without pushing an event", %{conn: conn} do
      org = insert_organization()
      project = create_project(%{title: "Nav Test", organization_id: org.id})

      {:ok, view, _html} = live(conn, ~p"/operator/projects/#{project.id}")

      assert {:error, {:live_redirect, %{to: "/operator/projects"}}} =
               view |> element("a", "Edit") |> render_click()
    end
  end

  describe "organization scoping" do
    defp insert_scoped_operator(org) do
      {:ok, operator} =
        %OperatorAccount{}
        |> OperatorAccount.changeset(%{
          email: "agent-#{org.id}@example.com",
          password: "password123",
          role: "agent",
          organization_id: org.id
        })
        |> Repo.insert()

      operator
    end

    test "org-scoped operator can view a project in their own organization", %{conn: conn} do
      org = insert_organization(name: "Own Org")
      project = create_project(%{title: "Own Project", organization_id: org.id})
      operator = insert_scoped_operator(org)

      conn = Plug.Conn.put_session(conn, :operator_id, operator.id)

      {:ok, _view, html} = live(conn, ~p"/operator/projects/#{project.id}")

      assert html =~ "Own Project"
    end

    test "org-scoped operator cannot view another organization's project", %{conn: conn} do
      org_a = insert_organization(name: "Org A")
      org_b = insert_organization(name: "Org B")
      foreign_project = create_project(%{title: "Foreign Project", organization_id: org_b.id})
      operator = insert_scoped_operator(org_a)

      conn = Plug.Conn.put_session(conn, :operator_id, operator.id)

      {:error, {:live_redirect, %{to: redirect_path}}} =
        live(conn, ~p"/operator/projects/#{foreign_project.id}")

      assert redirect_path == "/operator/projects"
    end

    test "redirects for non-integer project ids", %{conn: conn} do
      {:error, {:live_redirect, %{to: redirect_path}}} =
        live(conn, ~p"/operator/projects/abc")

      assert redirect_path == "/operator/projects"
    end
  end

  describe "task id scoping" do
    test "cycle_task_state ignores task ids from other projects", %{conn: conn} do
      org = insert_organization()
      project = create_project(%{title: "Mine", organization_id: org.id})

      other_org = insert_organization()
      other_project = create_project(%{title: "Theirs", organization_id: other_org.id})

      foreign_task =
        create_task(%{title: "Foreign task", project_id: other_project.id, state: :open})

      {:ok, view, _html} = live(conn, ~p"/operator/projects/#{project.id}")

      render_click(view, "cycle_task_state", %{"id" => to_string(foreign_task.id)})

      assert Repo.get!(Task, foreign_task.id).state == :open
    end

    test "delete_task ignores task ids from other projects", %{conn: conn} do
      org = insert_organization()
      project = create_project(%{title: "Mine", organization_id: org.id})

      other_org = insert_organization()
      other_project = create_project(%{title: "Theirs", organization_id: other_org.id})
      foreign_task = create_task(%{title: "Foreign task", project_id: other_project.id})

      {:ok, view, _html} = live(conn, ~p"/operator/projects/#{project.id}")

      render_click(view, "delete_task", %{"id" => to_string(foreign_task.id)})

      assert Repo.get(Task, foreign_task.id) != nil
    end

    test "task mutations ignore non-integer ids", %{conn: conn} do
      org = insert_organization()
      project = create_project(%{title: "Mine", organization_id: org.id})

      {:ok, view, _html} = live(conn, ~p"/operator/projects/#{project.id}")

      # Must not raise
      render_click(view, "cycle_task_state", %{"id" => "not-a-number"})
      render_click(view, "delete_task", %{"id" => "not-a-number"})
    end
  end
end
