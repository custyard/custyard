defmodule Custyard.Projects do
  @moduledoc """
  Context for project queries and operations.
  """

  alias Custyard.{Project, Repo, Task}
  import Ecto.Query

  @doc """
  List all projects for operator view, with organization preloaded.
  """
  def list_for_operator do
    from(p in Project,
      where: p.is_template == false,
      order_by: [desc: p.inserted_at],
      preload: [:tasks, :organization]
    )
    |> Repo.all()
    |> Enum.map(&with_progress/1)
  end

  @doc """
  List projects for a specific organization (operator view).
  """
  def list_for_organization(org_id) do
    from(p in Project,
      where: p.organization_id == ^org_id,
      where: p.is_template == false,
      order_by: [desc: p.inserted_at],
      preload: [:tasks, :organization]
    )
    |> Repo.all()
    |> Enum.map(&with_progress/1)
  end

  @doc """
  List portal-visible projects for an organization.
  """
  def list_portal_visible(org_id) do
    from(p in Project,
      where: p.organization_id == ^org_id,
      where: p.portal_visible == true,
      order_by: [desc: p.inserted_at],
      preload: [:tasks]
    )
    |> Repo.all()
    |> Enum.map(&with_progress/1)
  end

  @doc """
  Get a single project by ID for portal viewing.
  Returns `{:ok, project}` or `{:error, :not_found}` or `{:error, :not_visible}`.
  """
  def get_portal_project(id, org_id) do
    case Repo.get(Project, id) do
      nil ->
        {:error, :not_found}

      project ->
        cond do
          project.organization_id != org_id ->
            {:error, :not_found}

          not project.portal_visible ->
            {:error, :not_visible}

          true ->
            project =
              project
              |> Repo.preload(
                tasks: from(t in Task, where: t.portal_visible == true, order_by: t.inserted_at)
              )
              |> with_progress()

            {:ok, project}
        end
    end
  end

  @doc """
  Get a project by ID (operator access).
  """
  def get_project!(id) do
    Repo.get!(Project, id)
    |> Repo.preload(:tasks)
    |> with_progress()
  end

  @doc """
  Create a project.
  """
  def create_project(attrs) do
    %Project{}
    |> Project.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Update a project.
  """
  def update_project(project, attrs) do
    project
    |> Project.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Delete a project.
  """
  def delete_project(project) do
    Repo.delete(project)
  end

  @doc """
  List all project templates.
  Templates are projects with is_template=true.
  """
  def list_templates do
    from(p in Project,
      where: p.is_template == true,
      order_by: [asc: p.title],
      preload: [:tasks]
    )
    |> Repo.all()
  end

  @doc """
  Create a new project from a template.

  Copies the template's title, description, and tasks to a new project.
  Task due dates are calculated by applying the original offset from the
  template's start_date to the new project's start_date.

  ## Parameters
    - template: The template project (must have is_template=true)
    - org_id: The organization ID for the new project
    - start_date: The start date for the new project

  ## Returns
    - `{:ok, project}` on success
    - `{:error, :not_a_template}` if the project is not a template
    - `{:error, changeset}` on validation failure
  """
  def create_from_template(%Project{is_template: true} = template, org_id, start_date) do
    template = Repo.preload(template, :tasks)

    project_attrs = %{
      title: template.title,
      description: template.description,
      start_date: start_date,
      target_completion_date: calculate_target_date(template, start_date),
      portal_visible: true,
      project_type: :customer,
      is_template: false,
      organization_id: org_id
    }

    Repo.transaction(fn ->
      with {:ok, project} <- create_project(project_attrs),
           {:ok, _tasks} <- create_tasks_from_template(project, template, start_date) do
        Repo.preload(project, :tasks) |> with_progress()
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def create_from_template(%Project{is_template: false}, _org_id, _start_date) do
    {:error, :not_a_template}
  end

  def create_from_template(nil, _org_id, _start_date) do
    {:error, :not_a_template}
  end

  # Calculate target completion date by preserving the duration from the template
  defp calculate_target_date(%Project{start_date: nil}, _new_start), do: nil
  defp calculate_target_date(%Project{target_completion_date: nil}, _new_start), do: nil

  defp calculate_target_date(
         %Project{start_date: template_start, target_completion_date: template_target},
         new_start
       ) do
    duration_days = Date.diff(template_target, template_start)
    Date.add(new_start, duration_days)
  end

  # Create tasks from template tasks, calculating due dates relative to new start date
  defp create_tasks_from_template(project, template, new_start_date) do
    template_start = template.start_date

    results =
      Enum.map(template.tasks, fn task ->
        due_at = calculate_task_due_at(task.due_at, template_start, new_start_date)

        %Task{}
        |> Task.changeset(%{
          title: task.title,
          state: :open,
          portal_visible: task.portal_visible,
          due_at: due_at,
          project_id: project.id
        })
        |> Repo.insert()
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(errors) do
      {:ok, Enum.map(results, fn {:ok, task} -> task end)}
    else
      {:error, elem(hd(errors), 1)}
    end
  end

  # Calculate new due_at by applying the same offset from template start to new start
  defp calculate_task_due_at(nil, _template_start, _new_start), do: nil
  defp calculate_task_due_at(_due_at, nil, _new_start), do: nil

  defp calculate_task_due_at(due_at, template_start, new_start) do
    # Convert template_start (Date) to DateTime for comparison
    template_start_dt = DateTime.new!(template_start, ~T[00:00:00], "Etc/UTC")
    offset_seconds = DateTime.diff(due_at, template_start_dt)

    # Apply offset to new start date
    new_start_dt = DateTime.new!(new_start, ~T[00:00:00], "Etc/UTC")
    DateTime.add(new_start_dt, offset_seconds)
  end

  @doc """
  Calculate and attach progress data to a project.

  Returns the project with its virtual `:progress` field populated:
  - `total`: total number of tasks
  - `done`: number of completed tasks
  - `percentage`: completion percentage (0-100)

  Requires tasks to be preloaded.
  """
  def with_progress(project) do
    tasks = project.tasks || []
    total = length(tasks)
    done = Enum.count(tasks, &(&1.state == :done))

    percentage =
      if total > 0 do
        round(done / total * 100)
      else
        0
      end

    # Use struct syntax to properly assign the virtual field
    %{project | progress: %{total: total, done: done, percentage: percentage}}
  end
end
