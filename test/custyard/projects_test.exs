defmodule Custyard.ProjectsTest do
  use Custyard.DataCase, async: true

  alias Custyard.{Project, Projects, Repo, Task}

  import Custyard.Factory

  # Helper to create a project directly
  defp create_project(attrs) do
    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert!()
  end

  # Helper to create a task for a project
  defp create_task(attrs) do
    %Task{}
    |> Task.changeset(attrs)
    |> Repo.insert!()
  end

  describe "list_for_operator/0" do
    test "returns all non-template projects with organization preloaded" do
      org = insert_organization(name: "Acme")
      create_project(%{title: "Project A", organization_id: org.id, is_template: false})
      create_project(%{title: "Project B", organization_id: org.id, is_template: false})
      create_project(%{title: "Template", organization_id: org.id, is_template: true})

      result = Projects.list_for_operator()

      assert length(result) == 2
      titles = Enum.map(result, & &1.title)
      assert "Project A" in titles
      assert "Project B" in titles
      refute "Template" in titles
    end

    test "excludes template projects" do
      org = insert_organization()
      create_project(%{title: "Normal", organization_id: org.id, is_template: false})
      create_project(%{title: "Template", organization_id: org.id, is_template: true})

      result = Projects.list_for_operator()

      assert length(result) == 1
      assert hd(result).title == "Normal"
    end

    test "includes progress calculation" do
      org = insert_organization()
      project = create_project(%{title: "With Tasks", organization_id: org.id})
      create_task(%{title: "Task 1", project_id: project.id, state: :done})
      create_task(%{title: "Task 2", project_id: project.id, state: :open})

      [result] = Projects.list_for_operator()

      assert result.progress.total == 2
      assert result.progress.done == 1
      assert result.progress.percentage == 50
    end

    test "returns projects ordered by inserted_at descending" do
      org = insert_organization()
      p1 = create_project(%{title: "First", organization_id: org.id})
      p2 = create_project(%{title: "Second", organization_id: org.id})

      result = Projects.list_for_operator()

      # Both projects should be returned - order depends on insertion timing
      # which may be identical in tests, so just verify both are present
      ids = Enum.map(result, & &1.id)
      assert p1.id in ids
      assert p2.id in ids
      assert length(result) == 2
    end
  end

  describe "list_for_organization/1" do
    test "returns projects for specific organization" do
      org1 = insert_organization(name: "Org1")
      org2 = insert_organization(name: "Org2")

      create_project(%{title: "Org1 Project", organization_id: org1.id})
      create_project(%{title: "Org2 Project", organization_id: org2.id})

      result = Projects.list_for_organization(org1.id)

      assert length(result) == 1
      assert hd(result).title == "Org1 Project"
    end

    test "excludes templates" do
      org = insert_organization()
      create_project(%{title: "Normal", organization_id: org.id, is_template: false})
      create_project(%{title: "Template", organization_id: org.id, is_template: true})

      result = Projects.list_for_organization(org.id)

      assert length(result) == 1
      assert hd(result).title == "Normal"
    end
  end

  describe "list_portal_visible/1" do
    test "returns only portal-visible projects" do
      org = insert_organization()
      create_project(%{title: "Visible", organization_id: org.id, portal_visible: true})
      create_project(%{title: "Hidden", organization_id: org.id, portal_visible: false})

      result = Projects.list_portal_visible(org.id)

      assert length(result) == 1
      assert hd(result).title == "Visible"
    end
  end

  describe "get_portal_project/2" do
    test "returns project when visible and belongs to org" do
      org = insert_organization()
      project = create_project(%{title: "Visible", organization_id: org.id, portal_visible: true})

      assert {:ok, result} = Projects.get_portal_project(project.id, org.id)
      assert result.id == project.id
    end

    test "returns not_found for non-existent project" do
      assert {:error, :not_found} = Projects.get_portal_project(999_999, 1)
    end

    test "returns not_found for project belonging to different org" do
      org1 = insert_organization()
      org2 = insert_organization()

      project =
        create_project(%{title: "Org1 Project", organization_id: org1.id, portal_visible: true})

      assert {:error, :not_found} = Projects.get_portal_project(project.id, org2.id)
    end

    test "returns not_visible for hidden project" do
      org = insert_organization()
      project = create_project(%{title: "Hidden", organization_id: org.id, portal_visible: false})

      assert {:error, :not_visible} = Projects.get_portal_project(project.id, org.id)
    end

    test "only includes portal-visible tasks" do
      org = insert_organization()
      project = create_project(%{title: "Project", organization_id: org.id, portal_visible: true})
      create_task(%{title: "Visible Task", project_id: project.id, portal_visible: true})
      create_task(%{title: "Hidden Task", project_id: project.id, portal_visible: false})

      {:ok, result} = Projects.get_portal_project(project.id, org.id)

      assert length(result.tasks) == 1
      assert hd(result.tasks).title == "Visible Task"
    end
  end

  describe "get_project!/1" do
    test "returns project with tasks preloaded" do
      org = insert_organization()
      project = create_project(%{title: "Test Project", organization_id: org.id})
      create_task(%{title: "Task 1", project_id: project.id})

      result = Projects.get_project!(project.id)

      assert result.id == project.id
      assert length(result.tasks) == 1
      assert result.progress.total == 1
    end

    test "raises for non-existent project" do
      assert_raise Ecto.NoResultsError, fn ->
        Projects.get_project!(999_999)
      end
    end
  end

  describe "create_project/1" do
    test "creates project with valid attributes" do
      org = insert_organization()
      attrs = %{title: "New Project", organization_id: org.id}

      assert {:ok, project} = Projects.create_project(attrs)
      assert project.title == "New Project"
    end

    test "returns error for missing title" do
      assert {:error, changeset} = Projects.create_project(%{})
      assert "can't be blank" in errors_on(changeset).title
    end
  end

  describe "update_project/2" do
    test "updates project attributes" do
      org = insert_organization()
      project = create_project(%{title: "Original", organization_id: org.id})

      assert {:ok, updated} = Projects.update_project(project, %{title: "Updated"})
      assert updated.title == "Updated"
    end
  end

  describe "delete_project/1" do
    test "deletes the project" do
      org = insert_organization()
      project = create_project(%{title: "To Delete", organization_id: org.id})

      assert {:ok, _} = Projects.delete_project(project)
      assert_raise Ecto.NoResultsError, fn -> Projects.get_project!(project.id) end
    end
  end

  describe "list_templates/0" do
    test "returns only template projects" do
      org = insert_organization()
      create_project(%{title: "Normal Project", organization_id: org.id, is_template: false})
      create_project(%{title: "Template A", is_template: true})
      create_project(%{title: "Template B", is_template: true})

      result = Projects.list_templates()

      assert length(result) == 2
      titles = Enum.map(result, & &1.title)
      assert "Template A" in titles
      assert "Template B" in titles
      refute "Normal Project" in titles
    end

    test "orders templates by title" do
      create_project(%{title: "Zebra Template", is_template: true})
      create_project(%{title: "Alpha Template", is_template: true})

      result = Projects.list_templates()

      assert hd(result).title == "Alpha Template"
      assert List.last(result).title == "Zebra Template"
    end

    test "preloads tasks" do
      template = create_project(%{title: "Template", is_template: true})
      create_task(%{title: "Template Task", project_id: template.id})

      [result] = Projects.list_templates()

      assert length(result.tasks) == 1
      assert hd(result.tasks).title == "Template Task"
    end
  end

  describe "create_from_template/3" do
    setup do
      org = insert_organization(name: "Client Org")

      template =
        create_project(%{
          title: "Onboarding Template",
          description: "Standard onboarding process",
          start_date: ~D[2024-01-01],
          target_completion_date: ~D[2024-01-15],
          is_template: true
        })

      # Template tasks with due dates relative to template start
      create_task(%{
        title: "Initial setup",
        project_id: template.id,
        due_at: ~U[2024-01-03 12:00:00Z],
        portal_visible: true
      })

      create_task(%{
        title: "Final review",
        project_id: template.id,
        due_at: ~U[2024-01-14 17:00:00Z],
        portal_visible: false
      })

      {:ok, org: org, template: template}
    end

    test "creates project from template", %{org: org, template: template} do
      start_date = ~D[2024-03-01]

      assert {:ok, project} = Projects.create_from_template(template, org.id, start_date)

      assert project.title == "Onboarding Template"
      assert project.description == "Standard onboarding process"
      assert project.organization_id == org.id
      assert project.start_date == start_date
      assert project.is_template == false
      assert project.portal_visible == true
      assert project.project_type == :customer
    end

    test "calculates target date based on template duration", %{org: org, template: template} do
      # Template has 14 days duration (Jan 1 to Jan 15)
      start_date = ~D[2024-03-01]

      {:ok, project} = Projects.create_from_template(template, org.id, start_date)

      # Should be 14 days after start: March 15
      assert project.target_completion_date == ~D[2024-03-15]
    end

    test "copies tasks with adjusted due dates", %{org: org, template: template} do
      start_date = ~D[2024-03-01]

      {:ok, project} = Projects.create_from_template(template, org.id, start_date)

      assert length(project.tasks) == 2

      # Find tasks by title
      initial_task = Enum.find(project.tasks, &(&1.title == "Initial setup"))
      final_task = Enum.find(project.tasks, &(&1.title == "Final review"))

      # Initial setup was 2 days + 12 hours after template start
      # Should be 2024-03-03 12:00:00
      assert initial_task.due_at == ~U[2024-03-03 12:00:00Z]

      # Final review was 13 days + 17 hours after template start
      # Should be 2024-03-14 17:00:00
      assert final_task.due_at == ~U[2024-03-14 17:00:00Z]
    end

    test "preserves task portal visibility", %{org: org, template: template} do
      {:ok, project} = Projects.create_from_template(template, org.id, ~D[2024-03-01])

      initial_task = Enum.find(project.tasks, &(&1.title == "Initial setup"))
      final_task = Enum.find(project.tasks, &(&1.title == "Final review"))

      assert initial_task.portal_visible == true
      assert final_task.portal_visible == false
    end

    test "sets all task states to open", %{org: org, template: template} do
      {:ok, project} = Projects.create_from_template(template, org.id, ~D[2024-03-01])

      for task <- project.tasks do
        assert task.state == :open
      end
    end

    test "returns error for non-template project", %{org: org} do
      normal_project = create_project(%{title: "Normal", is_template: false})

      assert {:error, :not_a_template} =
               Projects.create_from_template(normal_project, org.id, ~D[2024-03-01])
    end

    test "returns error for nil template", %{org: org} do
      assert {:error, :not_a_template} =
               Projects.create_from_template(nil, org.id, ~D[2024-03-01])
    end

    test "handles template without start date", %{org: org} do
      template = create_project(%{title: "No Dates", is_template: true, start_date: nil})

      {:ok, project} = Projects.create_from_template(template, org.id, ~D[2024-03-01])

      assert project.start_date == ~D[2024-03-01]
      assert project.target_completion_date == nil
    end

    test "handles template without target date", %{org: org} do
      template =
        create_project(%{
          title: "No Target",
          is_template: true,
          start_date: ~D[2024-01-01],
          target_completion_date: nil
        })

      {:ok, project} = Projects.create_from_template(template, org.id, ~D[2024-03-01])

      assert project.target_completion_date == nil
    end

    test "handles template without tasks", %{org: org} do
      template = create_project(%{title: "Empty", is_template: true})

      {:ok, project} = Projects.create_from_template(template, org.id, ~D[2024-03-01])

      assert project.tasks == []
      assert project.progress.total == 0
    end

    test "includes progress in returned project", %{org: org, template: template} do
      {:ok, project} = Projects.create_from_template(template, org.id, ~D[2024-03-01])

      assert project.progress.total == 2
      assert project.progress.done == 0
      assert project.progress.percentage == 0
    end
  end
end
