defmodule CustyardWeb.Portal.ProjectLiveTest do
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Custyard.Factory

  describe "mount" do
    test "renders project details page", %{conn: conn} do
      org = insert_organization()
      project = insert_project(organization_id: org.id, title: "Website Redesign")

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}/projects/#{project.id}")

      assert html =~ "Website Redesign"
      assert html =~ "Back to projects"
    end

    test "shows project description when present", %{conn: conn} do
      org = insert_organization()

      project =
        insert_project(
          organization_id: org.id,
          description: "A complete redesign of the company website"
        )

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}/projects/#{project.id}")

      assert html =~ "A complete redesign of the company website"
    end

    test "redirects to projects list when project not found", %{conn: conn} do
      org = insert_organization()

      {:error, {:live_redirect, %{to: redirect_path}}} =
        live(conn, ~p"/p/#{org.token}/projects/999999")

      assert redirect_path =~ "/projects"
    end

    test "redirects when project belongs to different organization", %{conn: conn} do
      org1 = insert_organization()
      org2 = insert_organization()
      project = insert_project(organization_id: org2.id)

      {:error, {:live_redirect, %{to: redirect_path}}} =
        live(conn, ~p"/p/#{org1.token}/projects/#{project.id}")

      assert redirect_path =~ "/projects"
    end

    test "redirects when project is not portal visible", %{conn: conn} do
      org = insert_organization()
      project = insert_project(organization_id: org.id, portal_visible: false)

      {:error, {:live_redirect, %{to: redirect_path}}} =
        live(conn, ~p"/p/#{org.token}/projects/#{project.id}")

      assert redirect_path =~ "/projects"
    end
  end

  describe "progress display" do
    test "shows progress when project has tasks", %{conn: conn} do
      org = insert_organization()
      project = insert_project(organization_id: org.id)
      _task1 = insert_task(project_id: project.id, state: :done)
      _task2 = insert_task(project_id: project.id, state: :open)

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}/projects/#{project.id}")

      assert html =~ "Progress"
      assert html =~ "1 of 2 tasks completed"
      assert html =~ "50%"
    end

    test "shows empty tasks message when no tasks", %{conn: conn} do
      org = insert_organization()
      project = insert_project(organization_id: org.id)

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}/projects/#{project.id}")

      assert html =~ "No tasks in this project yet"
    end
  end

  describe "task list" do
    test "displays task titles", %{conn: conn} do
      org = insert_organization()
      project = insert_project(organization_id: org.id)
      _task = insert_task(project_id: project.id, title: "Implement login page")

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}/projects/#{project.id}")

      assert html =~ "Implement login page"
    end

    test "shows task state badges", %{conn: conn} do
      org = insert_organization()
      project = insert_project(organization_id: org.id)
      _task1 = insert_task(project_id: project.id, state: :open)
      _task2 = insert_task(project_id: project.id, state: :in_progress)
      _task3 = insert_task(project_id: project.id, state: :done)

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}/projects/#{project.id}")

      assert html =~ "Open"
      assert html =~ "In Progress"
      assert html =~ "Done"
    end
  end

  describe "navigation" do
    test "links back to projects list", %{conn: conn} do
      org = insert_organization()
      project = insert_project(organization_id: org.id)

      {:ok, view, _html} = live(conn, ~p"/p/#{org.token}/projects/#{project.id}")

      assert view |> element("a[href*='/projects']", "Back to projects") |> has_element?()
    end
  end
end
