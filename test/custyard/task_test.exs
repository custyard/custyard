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

    test "valid with conversation_id" do
      org = insert_organization()
      conv = insert_conversation(organization_id: org.id)
      attrs = build_task(conversation_id: conv.id)
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
      conv = insert_conversation(organization_id: org.id)

      attrs = build_task(organization_id: org.id, conversation_id: conv.id)
      changeset = Task.changeset(%Task{}, attrs)

      assert changeset.valid?
    end

    test "invalid without any parent association" do
      # Task without organization_id, conversation_id, or project_id
      attrs = build_task()
      changeset = Task.changeset(%Task{}, attrs)

      refute changeset.valid?

      assert "task must have an organization, conversation, or project" in errors_on(changeset).organization_id
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

    test "defaults portal_visible to true" do
      org = insert_organization()
      attrs = build_task(organization_id: org.id) |> Map.delete(:portal_visible)
      {:ok, task} = %Task{} |> Task.changeset(attrs) |> Repo.insert()

      assert task.portal_visible == true
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
