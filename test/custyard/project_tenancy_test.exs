defmodule Custyard.ProjectTenancyTest do
  use Custyard.DataCase, async: true
  import Custyard.Factory
  alias Custyard.{Project, Projects, Tenants}

  test "internal projects cannot be moved to another tenant through operator updates" do
    {:ok, tenant} =
      Tenants.create_tenant(%{
        name: "Projects",
        slug: "projects-#{System.unique_integer([:positive])}"
      })

    admin = insert_operator_account(role: "admin", tenant_id: tenant.id)

    {:ok, project} =
      Projects.create_project_for_operator(
        %{title: "Internal", project_type: :internal, portal_visible: false},
        admin
      )

    assert project.tenant_id == tenant.id

    assert {:error, changeset} =
             Projects.update_project_for_operator(project, %{tenant_id: 1}, admin)

    assert "cannot be changed for an existing project" in errors_on(changeset).tenant_id
    assert Repo.reload!(project).tenant_id == tenant.id
  end

  test "projects cannot attach another tenant's conversation or move through another customer" do
    {:ok, tenant} =
      Tenants.create_tenant(%{
        name: "Projects",
        slug: "projects-#{System.unique_integer([:positive])}"
      })

    org = insert_organization(tenant_id: tenant.id)
    foreign = insert_conversation()

    changeset =
      Project.changeset(%Project{}, %{
        title: "Bad link",
        organization_id: org.id,
        conversation_id: foreign.id
      })

    refute changeset.valid?
    assert "must belong to the project's workspace" in errors_on(changeset).conversation_id
    admin = insert_operator_account(role: "admin", tenant_id: tenant.id)

    assert {:error, changeset} =
             Projects.create_project_for_operator(
               %{
                 title: "Forged scope",
                 project_type: :internal,
                 portal_visible: false,
                 tenant_id: foreign.tenant_id,
                 conversation_id: foreign.id
               },
               admin
             )

    assert "must belong to the project's workspace" in errors_on(changeset).conversation_id
    project = insert_project(organization_id: org.id)

    assert {:error, changeset} =
             Projects.update_project(project, %{organization_id: foreign.organization_id})

    assert "cannot be changed for an existing project" in errors_on(changeset).tenant_id
  end

  test "moving a project synchronizes its tasks and keeps them editable" do
    org = insert_organization()
    destination = insert_organization(tenant_id: org.tenant_id)
    admin = insert_operator_account(role: "admin", tenant_id: org.tenant_id)
    project = insert_project(organization_id: org.id)
    {:ok, task} = Projects.create_task(project, %{title: "Follow up", portal_visible: true})

    assert {:ok, moved} =
             Projects.update_project_for_operator(
               project,
               %{organization_id: destination.id},
               admin
             )

    assert moved.organization_id == destination.id
    assert Repo.reload!(task).organization_id == destination.id
    assert Repo.reload!(task).portal_visible

    assert {:ok, _} =
             task
             |> Repo.reload!()
             |> Custyard.Task.changeset(%{title: "Still editable"})
             |> Repo.update()

    assert {:ok, _} = Projects.update_project(moved, %{organization_id: org.id})
    assert Repo.reload!(task).organization_id == org.id
  end

  test "a project move cannot carry a task away from its conversation's customer" do
    org = insert_organization()
    destination = insert_organization(tenant_id: org.tenant_id)
    admin = insert_operator_account(role: "admin", tenant_id: org.tenant_id)
    conversation = insert_conversation(organization_id: org.id)
    project = insert_project(organization_id: org.id)

    {:ok, task} =
      Projects.create_task(project, %{
        title: "Conversation task",
        conversation_id: conversation.id
      })

    for update <- [
          fn -> Projects.update_project(project, %{organization_id: destination.id}) end,
          fn ->
            Projects.update_project_for_operator(
              project,
              %{organization_id: destination.id},
              admin
            )
          end
        ] do
      assert {:error, changeset} = update.()

      assert errors_on(changeset).organization_id == [
               "cannot move tasks linked to another customer's conversation"
             ]

      assert Repo.reload!(project).organization_id == org.id
      assert Repo.reload!(task).organization_id == org.id
    end
  end
end
