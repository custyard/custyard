defmodule CustyardWeb.Portal.ProjectsListLiveTest do
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Custyard.Factory

  describe "mount" do
    test "renders projects page", %{conn: conn} do
      org = insert_organization()

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}/projects")

      assert html =~ "Projects"
      assert html =~ "Active projects and their progress"
    end

    test "shows empty state when no projects", %{conn: conn} do
      org = insert_organization()

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}/projects")

      assert html =~ "No active projects at this time"
    end

    test "lists portal-visible projects for the organization", %{conn: conn} do
      org = insert_organization()

      project1 = insert_project(organization_id: org.id, title: "Project Alpha")
      project2 = insert_project(organization_id: org.id, title: "Project Beta")

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}/projects")

      assert html =~ project1.title
      assert html =~ project2.title
    end

    test "does not show non-portal-visible projects", %{conn: conn} do
      org = insert_organization()

      visible_project =
        insert_project(organization_id: org.id, title: "Visible Project", portal_visible: true)

      hidden_project =
        insert_project(organization_id: org.id, title: "Hidden Project", portal_visible: false)

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}/projects")

      assert html =~ visible_project.title
      refute html =~ hidden_project.title
    end

    test "does not show projects from other organizations", %{conn: conn} do
      org1 = insert_organization()
      org2 = insert_organization()

      project1 = insert_project(organization_id: org1.id, title: "Org1 Project")
      project2 = insert_project(organization_id: org2.id, title: "Org2 Project")

      {:ok, _view, html} = live(conn, ~p"/p/#{org1.token}/projects")

      assert html =~ project1.title
      refute html =~ project2.title
    end

    test "shows project description when present", %{conn: conn} do
      org = insert_organization()

      _project =
        insert_project(organization_id: org.id, description: "This is a detailed description")

      {:ok, _view, html} = live(conn, ~p"/p/#{org.token}/projects")

      assert html =~ "This is a detailed description"
    end
  end

  describe "navigation" do
    test "links to individual project pages", %{conn: conn} do
      org = insert_organization()
      project = insert_project(organization_id: org.id, title: "Test Project")

      {:ok, view, _html} = live(conn, ~p"/p/#{org.token}/projects")

      assert view |> element("a[href*='/projects/#{project.id}']") |> has_element?()
    end

    test "links back to requests page", %{conn: conn} do
      org = insert_organization()

      {:ok, view, _html} = live(conn, ~p"/p/#{org.token}/projects")

      assert view |> element("a", "View Requests") |> has_element?()
    end
  end
end
