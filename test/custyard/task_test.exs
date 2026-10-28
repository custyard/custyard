defmodule Custyard.TaskTest do
  use Custyard.DataCase, async: true

  alias Custyard.Task

  import Custyard.Factory

  describe "changeset/2" do
    test "valid with organization_id" do
      org = insert_organization()
      attrs = build_task(organization_id: org.id)
      changeset = Task.changeset(%Task{}, attrs)

      assert changeset.valid?
    end

    test "valid with thread_id" do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)
      attrs = build_task(thread_id: conv.id)
      changeset = Task.changeset(%Task{}, attrs)

      assert changeset.valid?
    end

    test "valid with project_id" do
      org = insert_organization()
      project = insert_project(organization_id: org.id)
      attrs = build_task(project_id: project.id)
      changeset = Task.changeset(%Task{}, attrs)

      assert changeset.valid?
    end

    test "valid with multiple parent associations" do
      org = insert_organization()
      conv = insert_thread(organization_id: org.id)

      attrs = build_task(organization_id: org.id, thread_id: conv.id)
      changeset = Task.changeset(%Task{}, attrs)

      assert changeset.valid?
    end

    test "invalid without any parent association" do
      # Task without organization_id, thread_id, or project_id
      attrs = build_task()
      changeset = Task.changeset(%Task{}, attrs)

      refute changeset.valid?

      assert "task must have an organization, thread, or project" in errors_on(changeset).organization_id
    end

    test "requires title" do
      org = insert_organization()
      attrs = build_task(organization_id: org.id) |> Map.delete(:title)
      changeset = Task.changeset(%Task{}, attrs)

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).title
    end

    test "accepts valid state values" do
      org = insert_organization()

      for state <- [:open, :in_progress, :done] do
        attrs = build_task(organization_id: org.id, state: state)
        changeset = Task.changeset(%Task{}, attrs)

        assert changeset.valid?, "Expected state #{state} to be valid"
      end
    end

    test "rejects invalid state value" do
      org = insert_organization()
      attrs = build_task(organization_id: org.id, state: :invalid_state)
      changeset = Task.changeset(%Task{}, attrs)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).state
    end

    test "defaults to open state" do
      org = insert_organization()
      attrs = build_task(organization_id: org.id) |> Map.delete(:state)
      {:ok, task} = %Task{} |> Task.changeset(attrs) |> Repo.insert()

      assert task.state == :open
    end

    test "new tasks are private unless explicitly shared" do
      org = insert_organization()
      attrs = build_task(organization_id: org.id) |> Map.delete(:portal_visible)
      {:ok, task} = %Task{} |> Task.changeset(attrs) |> Repo.insert()

      assert task.portal_visible == false
    end

    test "the database default is private for inserts outside the task schema" do
      org = insert_organization()

      {1, [%{id: id}]} =
        Repo.insert_all(
          "tasks",
          [
            %{
              title: "Direct insert",
              tenant_id: org.tenant_id,
              organization_id: org.id,
              inserted_at: "2026-10-27 00:00:00",
              updated_at: "2026-10-27 00:00:00"
            }
          ],
          returning: [:id]
        )

      refute Repo.get!(Task, id).portal_visible
    end

    test "UTC input round trips and invalid input does not clear a deadline" do
      org = insert_organization()

      {:ok, task} =
        %Task{}
        |> Task.changeset(%{
          title: "Follow up",
          organization_id: org.id,
          due_at: "2026-10-28T15:30"
        })
        |> Repo.insert()

      assert task.due_at == ~U[2026-10-28 15:30:00Z]
      invalid = Task.changeset(task, %{due_at: "not-a-date"})
      refute invalid.valid?
      assert "is invalid" in errors_on(invalid).due_at
      assert Repo.get!(Task, task.id).due_at == task.due_at
    end

    test "rejects conflicting parent organizations" do
      org = insert_organization()
      other = insert_organization()
      thread = insert_thread(organization_id: org.id)
      project = insert_project(organization_id: other.id)

      changeset =
        Task.changeset(%Task{}, %{
          title: "Cross scope",
          thread_id: thread.id,
          project_id: project.id
        })

      refute changeset.valid?
      assert "must belong to the thread's organization" in errors_on(changeset).project_id
    end

    test "unlinked tasks cannot connect parents from different workspaces" do
      {:ok, tenant} =
        Custyard.Tenants.create_tenant(%{
          name: "Other",
          slug: "task-#{System.unique_integer([:positive])}"
        })

      thread = insert_thread(source: :public_intake)

      project =
        %Custyard.Project{}
        |> Custyard.Project.internal_project_changeset(%{title: "Other", tenant_id: tenant.id})
        |> Repo.insert!()

      changeset =
        Task.changeset(%Task{}, %{
          title: "Cross workspace",
          thread_id: thread.id,
          project_id: project.id
        })

      refute changeset.valid?
      assert "must belong to the thread's workspace" in errors_on(changeset).project_id
    end
  end

  describe "state_changeset/2" do
    test "transitions to valid state" do
      org = insert_organization()
      task = insert_task(organization_id: org.id, state: :open)

      changeset = Task.state_changeset(task, :in_progress)

      assert changeset.valid?
      assert get_change(changeset, :state) == :in_progress
    end

    test "rejects invalid state transition" do
      org = insert_organization()
      task = insert_task(organization_id: org.id, state: :open)

      changeset = Task.state_changeset(task, :invalid)

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).state
    end
  end
end
