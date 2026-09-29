defmodule CustyardWeb.Portal.RealtimeTopicsTest do
  use CustyardWeb.ConnCase, async: false

  import Custyard.Factory
  import Phoenix.LiveViewTest

  alias Custyard.{OperatorAccount, Projects, Repo, Task}

  test "an open project list follows project and task changes", %{conn: conn} do
    org = insert_organization()
    {:ok, view, _} = live(conn, "/p/#{org.token}/projects")

    {:ok, project} = Projects.create_project(build_project(organization_id: org.id))
    assert render(view) =~ project.title

    {:ok, task} = Projects.create_task(project, build_task(portal_visible: true))
    assert render(view) =~ "0%"

    {:ok, _} = Projects.update_task_state(task, :done)
    assert render(view) =~ "100%"

    {:ok, _} = Projects.delete_project(project)
    refute render(view) =~ project.title
  end

  test "a new request appears in another open portal list", %{conn: conn} do
    org = insert_organization()
    {:ok, list_view, _} = live(conn, "/p/#{org.token}")
    {:ok, new_view, _} = live(conn, "/p/#{org.token}/new")

    new_view
    |> form("form", %{
      "subject" => "Fresh customer request",
      "body" => "Details of the request",
      "urgency" => "normal"
    })
    |> render_submit()

    assert render(list_view) =~ "Fresh customer request"
  end

  test "operator task changes reach an open portal list after commit", %{conn: conn} do
    org = insert_organization()
    {:ok, project} = Projects.create_project(build_project(organization_id: org.id))
    {:ok, portal_view, _} = live(conn, "/p/#{org.token}/projects")

    operator =
      %OperatorAccount{}
      |> OperatorAccount.changeset(%{email: "portal-task-operator@example.com"})
      |> Repo.insert!()

    operator_conn =
      Phoenix.ConnTest.build_conn()
      |> Phoenix.ConnTest.init_test_session(%{})
      |> Plug.Conn.put_session(:operator_id, operator.id)

    {:ok, operator_view, _} = live(operator_conn, "/operator/projects/#{project.id}")

    render_click(operator_view, "add_task", %{
      "title" => "Portal task",
      "portal_visible" => "true"
    })

    task = Repo.get_by!(Task, project_id: project.id, title: "Portal task")
    render_click(operator_view, "cycle_task_state", %{"id" => to_string(task.id)})
    render_click(operator_view, "cycle_task_state", %{"id" => to_string(task.id)})

    assert render(portal_view) =~ "100%"
  end
end
