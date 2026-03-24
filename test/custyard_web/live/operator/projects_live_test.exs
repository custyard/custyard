defmodule CustyardWeb.Operator.ProjectsLiveTest do
  use CustyardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Custyard.Factory

  alias Custyard.{OperatorAccount, Repo, Project, Task}

  setup %{conn: conn} do
    # Create and authenticate an operator
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

  # Helper to create projects
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
    test "renders projects list", %{conn: conn} do
      org = insert_organization(name: "Acme Corp")
      create_project(%{title: "Website Redesign", organization_id: org.id})
      create_project(%{title: "Mobile App", organization_id: org.id})

      {:ok, _view, html} = live(conn, ~p"/operator/projects")

      assert html =~ "Projects"
      assert html =~ "Website Redesign"
      assert html =~ "Mobile App"
    end

    test "shows organization dropdown", %{conn: conn} do
      insert_organization(name: "Org A")
      insert_organization(name: "Org B")

      {:ok, _view, html} = live(conn, ~p"/operator/projects")

      assert html =~ "All organizations"
      assert html =~ "Org A"
      assert html =~ "Org B"
    end

    test "shows empty state when no projects", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/operator/projects")

      assert html =~ "No projects found"
    end

    test "excludes template projects from list", %{conn: conn} do
      org = insert_organization()
      create_project(%{title: "Regular Project", organization_id: org.id, is_template: false})
      create_project(%{title: "Template Project", is_template: true})

      {:ok, _view, html} = live(conn, ~p"/operator/projects")

      assert html =~ "Regular Project"
      refute html =~ "Template Project"
    end
  end

  describe "project display" do
    test "shows project type badge", %{conn: conn} do
      org = insert_organization()

      create_project(%{
        title: "Customer Project",
        organization_id: org.id,
        project_type: :customer
      })

      create_project(%{title: "Internal Project", project_type: :internal, portal_visible: false})

      {:ok, _view, html} = live(conn, ~p"/operator/projects")

      assert html =~ "customer"
      assert html =~ "internal"
    end

    test "shows hidden badge for non-portal-visible projects", %{conn: conn} do
      org = insert_organization()
      create_project(%{title: "Hidden Project", organization_id: org.id, portal_visible: false})

      {:ok, _view, html} = live(conn, ~p"/operator/projects")

      assert html =~ "hidden"
    end

    test "shows progress ring", %{conn: conn} do
      org = insert_organization()
      project = create_project(%{title: "Progress Project", organization_id: org.id})
      create_task(%{title: "Done Task", project_id: project.id, state: :done})
      create_task(%{title: "Open Task", project_id: project.id, state: :open})

      {:ok, _view, html} = live(conn, ~p"/operator/projects")

      # 50% progress
      assert html =~ "50%"
      assert html =~ "1/2 tasks"
    end

    test "shows dates when set", %{conn: conn} do
      org = insert_organization()

      create_project(%{
        title: "Dated Project",
        organization_id: org.id,
        start_date: ~D[2024-03-01],
        target_completion_date: ~D[2024-04-15]
      })

      {:ok, _view, html} = live(conn, ~p"/operator/projects")

      assert html =~ "2024-03-01"
      assert html =~ "2024-04-15"
    end
  end

  describe "filter_org event" do
    test "filters projects by organization", %{conn: conn} do
      org1 = insert_organization(name: "Org One")
      org2 = insert_organization(name: "Org Two")

      create_project(%{title: "Org1 Project", organization_id: org1.id})
      create_project(%{title: "Org2 Project", organization_id: org2.id})

      {:ok, view, _html} = live(conn, ~p"/operator/projects")

      # Filter to org1
      html =
        view
        |> element("select[name=org]")
        |> render_change(%{org: org1.id})

      assert html =~ "Org1 Project"
      refute html =~ "Org2 Project"
    end

    test "shows all when filter cleared", %{conn: conn} do
      org = insert_organization()
      create_project(%{title: "Project A", organization_id: org.id})
      create_project(%{title: "Project B", organization_id: org.id})

      {:ok, view, _html} = live(conn, ~p"/operator/projects?org=#{org.id}")

      # Clear filter
      html =
        view
        |> element("select[name=org]")
        |> render_change(%{org: ""})

      assert html =~ "Project A"
      assert html =~ "Project B"
    end
  end

  describe "show_form event" do
    test "displays new project form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operator/projects")

      html =
        view
        |> element("button", "Add project")
        |> render_click()

      assert html =~ "New project"
      assert html =~ "Title"
      assert html =~ "Description"
      assert html =~ "Organization"
      assert html =~ "Start date"
      assert html =~ "Target completion"
      assert html =~ "Visible in client portal"
    end
  end

  describe "hide_form event" do
    test "hides the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operator/projects")

      view
      |> element("button", "Add project")
      |> render_click()

      html =
        view
        |> element("button", "Cancel")
        |> render_click()

      refute html =~ "New project"
    end
  end

  describe "edit_project event" do
    test "populates form with project data", %{conn: conn} do
      org = insert_organization(name: "Edit Org")

      project =
        create_project(%{
          title: "Edit Me",
          description: "Some description",
          organization_id: org.id,
          start_date: ~D[2024-01-15],
          target_completion_date: ~D[2024-02-28],
          portal_visible: true
        })

      {:ok, view, _html} = live(conn, ~p"/operator/projects")

      html =
        view
        |> element("[phx-click=edit_project][phx-value-id=\"#{project.id}\"]")
        |> render_click()

      assert html =~ "Edit project"
      assert html =~ "Edit Me"
      assert html =~ "Some description"
      assert html =~ "2024-01-15"
      assert html =~ "2024-02-28"
    end
  end

  describe "save_project event - create" do
    test "creates new project", %{conn: conn} do
      org = insert_organization(name: "New Project Org")

      {:ok, view, _html} = live(conn, ~p"/operator/projects")

      view
      |> element("button", "Add project")
      |> render_click()

      # Use hook to update form fields
      render_hook(view, "update_form", %{"field" => "title", "value" => "New Project"})

      render_hook(view, "update_form", %{
        "field" => "organization_id",
        "value" => to_string(org.id)
      })

      html =
        view
        |> element("form[phx-submit=save_project]")
        |> render_submit()

      assert html =~ "New Project"

      project = Repo.get_by(Project, title: "New Project")
      assert project.organization_id == org.id
      assert project.project_type == :customer
    end

    test "creates internal project when no organization selected", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/operator/projects")

      view
      |> element("button", "Add project")
      |> render_click()

      render_hook(view, "update_form", %{"field" => "title", "value" => "Internal Project"})
      # Uncheck portal visible (internal projects cannot be portal visible)
      render_hook(view, "update_form", %{"field" => "portal_visible", "value" => "false"})

      view
      |> element("form[phx-submit=save_project]")
      |> render_submit()

      project = Repo.get_by(Project, title: "Internal Project")
      assert project.organization_id == nil
      assert project.project_type == :internal
    end

    test "creates project with dates", %{conn: conn} do
      org = insert_organization()

      {:ok, view, _html} = live(conn, ~p"/operator/projects")

      view
      |> element("button", "Add project")
      |> render_click()

      render_hook(view, "update_form", %{"field" => "title", "value" => "Dated Project"})

      render_hook(view, "update_form", %{
        "field" => "organization_id",
        "value" => to_string(org.id)
      })

      render_hook(view, "update_form", %{"field" => "start_date", "value" => "2024-06-01"})

      render_hook(view, "update_form", %{
        "field" => "target_completion_date",
        "value" => "2024-08-31"
      })

      view
      |> element("form[phx-submit=save_project]")
      |> render_submit()

      project = Repo.get_by(Project, title: "Dated Project")
      assert project.start_date == ~D[2024-06-01]
      assert project.target_completion_date == ~D[2024-08-31]
    end
  end

  describe "save_project event - update" do
    test "updates existing project", %{conn: conn} do
      org = insert_organization()
      project = create_project(%{title: "Original Title", organization_id: org.id})

      {:ok, view, _html} = live(conn, ~p"/operator/projects")

      view
      |> element("[phx-click=edit_project][phx-value-id=\"#{project.id}\"]")
      |> render_click()

      render_hook(view, "update_form", %{"field" => "title", "value" => "Updated Title"})

      html =
        view
        |> element("form[phx-submit=save_project]")
        |> render_submit()

      assert html =~ "Updated Title"
      refute html =~ "Original Title"

      updated = Repo.get!(Project, project.id)
      assert updated.title == "Updated Title"
    end
  end

  describe "delete_project event" do
    test "deletes the project", %{conn: conn} do
      org = insert_organization()
      project = create_project(%{title: "To Delete", organization_id: org.id})

      {:ok, view, _html} = live(conn, ~p"/operator/projects")

      html =
        view
        |> element("[phx-click=delete_project][phx-value-id=\"#{project.id}\"]")
        |> render_click()

      refute html =~ "To Delete"
      assert Repo.get(Project, project.id) == nil
    end
  end

  describe "portal visibility checkbox" do
    test "creates project with portal visibility off", %{conn: conn} do
      org = insert_organization()

      {:ok, view, _html} = live(conn, ~p"/operator/projects")

      view
      |> element("button", "Add project")
      |> render_click()

      render_hook(view, "update_form", %{"field" => "title", "value" => "Hidden Project"})

      render_hook(view, "update_form", %{
        "field" => "organization_id",
        "value" => to_string(org.id)
      })

      # Uncheck portal_visible
      render_hook(view, "update_form", %{"field" => "portal_visible", "value" => "false"})

      view
      |> element("form[phx-submit=save_project]")
      |> render_submit()

      project = Repo.get_by(Project, title: "Hidden Project")
      assert project.portal_visible == false
    end
  end
end
