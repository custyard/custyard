defmodule Custyard.ProjectTenancyTest do
  use Custyard.DataCase, async: true
  import Custyard.Factory

  defp scope(staff),
    do: Custyard.Scope.for_staff(staff, Custyard.Tenants.get_tenant!(staff.tenant_id))

  alias Custyard.{Project, Projects, Tenants}

  test "internal projects cannot be moved to another tenant through staff updates" do
    {:ok, tenant} =
      Tenants.create_tenant(%{
        name: "Projects",
        slug: "projects-#{System.unique_integer([:positive])}"
      })

    admin = insert_staff_account(role: "admin", tenant_id: tenant.id)

    {:ok, project} =
      Projects.create(scope(admin), %{
        title: "Internal",
        project_type: :internal,
        portal_visible: false
      })

    assert project.tenant_id == tenant.id

    assert {:error, changeset} =
             Projects.update(scope(admin), project, %{tenant_id: insert_tenant().id})

    assert "cannot be changed for an existing project" in errors_on(changeset).tenant_id
    assert Repo.reload!(project).tenant_id == tenant.id
  end

  test "projects cannot attach another tenant's thread or move through another customer" do
    {:ok, tenant} =
      Tenants.create_tenant(%{
        name: "Projects",
        slug: "projects-#{System.unique_integer([:positive])}"
      })

    org = insert_organization(tenant_id: tenant.id)
    foreign = insert_thread()

    changeset =
      Project.changeset(%Project{}, %{
        title: "Bad link",
        organization_id: org.id,
        thread_id: foreign.id
      })

    refute changeset.valid?
    assert "must belong to the project's workspace" in errors_on(changeset).thread_id
    admin = insert_staff_account(role: "admin", tenant_id: tenant.id)

    assert {:error, changeset} =
             Projects.create(scope(admin), %{
               title: "Forged scope",
               project_type: :internal,
               portal_visible: false,
               tenant_id: foreign.tenant_id,
               thread_id: foreign.id
             })

    assert "must belong to the project's workspace" in errors_on(changeset).thread_id
    project = insert_project(organization_id: org.id)

    assert {:error, :unauthorized} =
             Projects.update(scope(admin), project, %{organization_id: foreign.organization_id})
  end

  test "moving a project synchronizes its tasks and keeps them editable" do
    org = insert_organization()
    destination = insert_organization(tenant_id: org.tenant_id)
    admin = insert_staff_account(role: "admin", tenant_id: org.tenant_id)
    project = insert_project(organization_id: org.id)
    {:ok, task} = Projects.create_task(project, %{title: "Follow up", portal_visible: true})

    assert {:ok, moved} =
             Projects.update(scope(admin), project, %{organization_id: destination.id})

    assert moved.organization_id == destination.id
    assert Repo.reload!(task).organization_id == destination.id
    assert Repo.reload!(task).portal_visible

    assert {:ok, _} =
             task
             |> Repo.reload!()
             |> Custyard.WorkItem.changeset(%{title: "Still editable"})
             |> Repo.update()

    assert {:ok, _} = Projects.update(staff_scope(), moved, %{organization_id: org.id})
    assert Repo.reload!(task).organization_id == org.id
  end

  test "a project move cannot carry a task away from its thread's customer" do
    org = insert_organization()
    destination = insert_organization(tenant_id: org.tenant_id)
    admin = insert_staff_account(role: "admin", tenant_id: org.tenant_id)
    thread = insert_thread(organization_id: org.id)
    project = insert_project(organization_id: org.id)

    {:ok, task} =
      Projects.create_task(project, %{
        title: "Thread task",
        thread_id: thread.id
      })

    for update <- [
          fn -> Projects.update(staff_scope(), project, %{organization_id: destination.id}) end,
          fn ->
            Projects.update(scope(admin), project, %{organization_id: destination.id})
          end
        ] do
      assert {:error, changeset} = update.()

      assert errors_on(changeset).organization_id == [
               "cannot move tasks linked to another customer's thread"
             ]

      assert Repo.reload!(project).organization_id == org.id
      assert Repo.reload!(task).organization_id == org.id
    end
  end
end
