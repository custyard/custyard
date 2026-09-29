defmodule CustyardWeb.Portal.RealtimeTopicsTest do
  use CustyardWeb.ConnCase, async: false

  import Custyard.Factory
  import Phoenix.LiveViewTest

  alias Custyard.Projects

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
end
